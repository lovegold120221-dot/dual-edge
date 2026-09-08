package ai.eburon.dualtranslate

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.AutomaticGainControl
import android.media.audiofx.NoiseSuppressor
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.max

class LivePcmAudioChannel(
    private val context: Context,
    private val flutterEngine: FlutterEngine,
) {
    companion object {
        private const val CHANNEL = "ai.eburon.translator/live_pcm_v1"
        private const val INPUT_CHANNEL = "ai.eburon.translator/live_pcm_input_v1"
        private const val DEFAULT_INPUT_SAMPLE_RATE = 16000
        private const val DEFAULT_OUTPUT_SAMPLE_RATE = 24000
    }

    private val playbackExecutor = Executors.newSingleThreadExecutor()
    private val captureExecutor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val playbackGeneration = AtomicInteger(0)
    private val captureGeneration = AtomicInteger(0)
    private val lock = Any()
    private val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    private var audioTrack: AudioTrack? = null
    private var audioRecord: AudioRecord? = null
    private var acousticEchoCanceler: AcousticEchoCanceler? = null
    private var noiseSuppressor: NoiseSuppressor? = null
    private var automaticGainControl: AutomaticGainControl? = null
    private var outputSampleRate: Int = DEFAULT_OUTPUT_SAMPLE_RATE
    private var inputSampleRate: Int = DEFAULT_INPUT_SAMPLE_RATE
    private var channel: MethodChannel? = null
    private var inputEventChannel: EventChannel? = null
    private var microphoneEventSink: EventChannel.EventSink? = null
    private var playbackSharesCaptureSession = false
    private var previousAudioMode: Int? = null
    private var previousSpeakerphoneOn: Boolean? = null
    private var previousCommunicationDevice: AudioDeviceInfo? = null

    fun register() {
        inputEventChannel = EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            INPUT_CHANNEL,
        ).also { eventChannel ->
            eventChannel.setStreamHandler(
                object : EventChannel.StreamHandler {
                    override fun onListen(
                        arguments: Any?,
                        events: EventChannel.EventSink?,
                    ) {
                        microphoneEventSink = events
                    }

                    override fun onCancel(arguments: Any?) {
                        microphoneEventSink = null
                    }
                },
            )
        }
        channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL,
        ).also { methodChannel ->
            methodChannel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "prepare" -> {
                        val requestedRate = call.argument<Int>("sampleRate")
                            ?: DEFAULT_OUTPUT_SAMPLE_RATE
                        try {
                            prepare(requestedRate)
                            result.success(null)
                        } catch (error: Exception) {
                            result.error("PCM_PREPARE_FAILED", error.message, null)
                        }
                    }

                    "write" -> {
                        val bytes = call.argument<ByteArray>("data")
                        val requestedRate = call.argument<Int>("sampleRate")
                            ?: DEFAULT_OUTPUT_SAMPLE_RATE
                        if (bytes == null || bytes.isEmpty()) {
                            result.success(null)
                        } else {
                            enqueue(bytes.copyOf(), requestedRate)
                            result.success(null)
                        }
                    }

                    "startCapture" -> {
                        val requestedRate = call.argument<Int>("sampleRate")
                            ?: DEFAULT_INPUT_SAMPLE_RATE
                        try {
                            startCapture(requestedRate)
                            result.success(null)
                        } catch (error: Exception) {
                            result.error("PCM_CAPTURE_FAILED", error.message, null)
                        }
                    }

                    "stopCapture" -> {
                        stopCapture()
                        result.success(null)
                    }

                    "stopPlayback" -> {
                        stopPlayback()
                        result.success(null)
                    }

                    "getProcessingState" -> result.success(processingState())

                    "stop" -> {
                        stopAll()
                        result.success(null)
                    }

                    else -> result.notImplemented()
                }
            }
        }
    }

    private fun prepare(requestedRate: Int) {
        synchronized(lock) {
            configureCommunicationRoutingLocked()
            if (audioTrack?.state == AudioTrack.STATE_INITIALIZED &&
                outputSampleRate == requestedRate
            ) {
                if (audioTrack?.playState != AudioTrack.PLAYSTATE_PLAYING) {
                    audioTrack?.play()
                }
                return
            }
            releaseTrackLocked(restoreRouting = false)
            outputSampleRate = requestedRate
            val minimum = AudioTrack.getMinBufferSize(
                requestedRate,
                AudioFormat.CHANNEL_OUT_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
            )
            check(minimum > 0) { "Android reported an invalid speaker buffer size." }
            val bufferSize = max(minimum * 4, requestedRate)
            val captureSessionId = audioRecord?.audioSessionId?.takeIf { it > 0 }
            audioTrack = buildAudioTrack(
                sampleRate = requestedRate,
                bufferSize = bufferSize,
                sharedSessionId = captureSessionId,
            )
            check(audioTrack?.state == AudioTrack.STATE_INITIALIZED) {
                "Android AudioTrack could not be initialized."
            }
            playbackSharesCaptureSession =
                captureSessionId != null && audioTrack?.audioSessionId == captureSessionId
            audioTrack?.play()
        }
    }

    private fun buildAudioTrack(
        sampleRate: Int,
        bufferSize: Int,
        sharedSessionId: Int?,
    ): AudioTrack {
        fun builder(): AudioTrack.Builder {
            val trackBuilder = AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build(),
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(sampleRate)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                        .build(),
                )
                .setTransferMode(AudioTrack.MODE_STREAM)
                .setBufferSizeInBytes(bufferSize)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                trackBuilder.setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
            }
            return trackBuilder
        }

        if (sharedSessionId != null) {
            val sharedTrack = runCatching {
                builder().setSessionId(sharedSessionId).build()
            }.getOrNull()
            if (sharedTrack?.state == AudioTrack.STATE_INITIALIZED) return sharedTrack
            sharedTrack?.release()
        }
        return builder().build()
    }

    private fun enqueue(bytes: ByteArray, requestedRate: Int) {
        val writeGeneration = playbackGeneration.get()
        playbackExecutor.execute {
            if (writeGeneration != playbackGeneration.get()) return@execute
            synchronized(lock) {
                if (writeGeneration != playbackGeneration.get()) return@synchronized
                prepare(requestedRate)
                audioTrack?.write(
                    bytes,
                    0,
                    bytes.size,
                    AudioTrack.WRITE_BLOCKING,
                )
            }
        }
    }

    @SuppressLint("MissingPermission")
    private fun startCapture(requestedRate: Int) {
        check(
            context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) ==
                PackageManager.PERMISSION_GRANTED,
        ) { "Microphone permission was denied." }

        val record: AudioRecord
        val readBufferSize: Int
        val readGeneration: Int
        synchronized(lock) {
            if (audioRecord?.recordingState == AudioRecord.RECORDSTATE_RECORDING &&
                inputSampleRate == requestedRate
            ) {
                return
            }
            releaseRecordLocked(restoreRouting = false)
            configureCommunicationRoutingLocked()
            inputSampleRate = requestedRate

            val minimum = AudioRecord.getMinBufferSize(
                requestedRate,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
            )
            check(minimum > 0) { "Android reported an invalid microphone buffer size." }
            readBufferSize = max(minimum * 2, requestedRate / 5)
            record = AudioRecord.Builder()
                .setAudioSource(MediaRecorder.AudioSource.VOICE_COMMUNICATION)
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(requestedRate)
                        .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
                        .build(),
                )
                .setBufferSizeInBytes(readBufferSize)
                .build()
            check(record.state == AudioRecord.STATE_INITIALIZED) {
                "Android AudioRecord could not be initialized."
            }

            acousticEchoCanceler = createAcousticEchoCanceler(record.audioSessionId)
            noiseSuppressor = createNoiseSuppressor(record.audioSessionId)
            automaticGainControl = createAutomaticGainControl(record.audioSessionId)
            record.startRecording()
            check(record.recordingState == AudioRecord.RECORDSTATE_RECORDING) {
                "Android could not start microphone capture."
            }
            audioRecord = record
            readGeneration = captureGeneration.incrementAndGet()
        }

        captureExecutor.execute {
            readMicrophone(record, readBufferSize, readGeneration)
        }
    }

    private fun readMicrophone(
        record: AudioRecord,
        platformBufferSize: Int,
        readGeneration: Int,
    ) {
        val chunk = ByteArray(max(1280, minOf(platformBufferSize, 4096)))
        while (readGeneration == captureGeneration.get()) {
            val bytesRead = record.read(
                chunk,
                0,
                chunk.size,
                AudioRecord.READ_BLOCKING,
            )
            if (bytesRead <= 0) break
            val data = chunk.copyOf(bytesRead)
            mainHandler.post {
                if (readGeneration == captureGeneration.get()) {
                    microphoneEventSink?.success(data)
                }
            }
        }
    }

    private fun createAcousticEchoCanceler(sessionId: Int): AcousticEchoCanceler? =
        if (AcousticEchoCanceler.isAvailable()) {
            runCatching {
                AcousticEchoCanceler.create(sessionId)?.apply { enabled = true }
            }.getOrNull()
        } else {
            null
        }

    private fun createNoiseSuppressor(sessionId: Int): NoiseSuppressor? =
        if (NoiseSuppressor.isAvailable()) {
            runCatching {
                NoiseSuppressor.create(sessionId)?.apply { enabled = true }
            }.getOrNull()
        } else {
            null
        }

    private fun createAutomaticGainControl(sessionId: Int): AutomaticGainControl? =
        if (AutomaticGainControl.isAvailable()) {
            runCatching {
                AutomaticGainControl.create(sessionId)?.apply { enabled = true }
            }.getOrNull()
        } else {
            null
        }

    private fun stopCapture() {
        captureGeneration.incrementAndGet()
        synchronized(lock) { releaseRecordLocked(restoreRouting = true) }
    }

    private fun stopPlayback() {
        playbackGeneration.incrementAndGet()
        playbackExecutor.execute {
            synchronized(lock) { releaseTrackLocked(restoreRouting = true) }
        }
    }

    private fun stopAll() {
        captureGeneration.incrementAndGet()
        playbackGeneration.incrementAndGet()
        synchronized(lock) {
            releaseRecordLocked(restoreRouting = false)
            releaseTrackLocked(restoreRouting = false)
            restoreCommunicationRoutingLocked()
        }
    }

    private fun configureCommunicationRoutingLocked() {
        if (previousAudioMode == null) {
            previousAudioMode = audioManager.mode
            @Suppress("DEPRECATION")
            previousSpeakerphoneOn = audioManager.isSpeakerphoneOn
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                previousCommunicationDevice = audioManager.communicationDevice
            }
        }
        audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val speaker = audioManager.availableCommunicationDevices.firstOrNull {
                it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
            }
            if (speaker != null) audioManager.setCommunicationDevice(speaker)
        } else {
            @Suppress("DEPRECATION")
            audioManager.isSpeakerphoneOn = true
        }
    }

    private fun restoreCommunicationRoutingLocked() {
        val savedMode = previousAudioMode ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val savedDevice = previousCommunicationDevice
            if (savedDevice != null) {
                audioManager.setCommunicationDevice(savedDevice)
            } else {
                audioManager.clearCommunicationDevice()
            }
        } else {
            @Suppress("DEPRECATION")
            audioManager.isSpeakerphoneOn = previousSpeakerphoneOn ?: false
        }
        audioManager.mode = savedMode
        previousAudioMode = null
        previousSpeakerphoneOn = null
        previousCommunicationDevice = null
    }

    private fun restoreRoutingIfIdleLocked() {
        if (audioRecord == null && audioTrack == null) {
            restoreCommunicationRoutingLocked()
        }
    }

    private fun releaseRecordLocked(restoreRouting: Boolean) {
        try {
            audioRecord?.stop()
        } catch (_: IllegalStateException) {
            // Capture may already be stopped after an Android audio interruption.
        }
        acousticEchoCanceler?.release()
        noiseSuppressor?.release()
        automaticGainControl?.release()
        acousticEchoCanceler = null
        noiseSuppressor = null
        automaticGainControl = null
        audioRecord?.release()
        audioRecord = null
        if (restoreRouting) restoreRoutingIfIdleLocked()
    }

    private fun releaseTrackLocked(restoreRouting: Boolean) {
        try {
            audioTrack?.pause()
            audioTrack?.flush()
            audioTrack?.stop()
        } catch (_: IllegalStateException) {
            // Playback may already be stopped after an Android audio interruption.
        }
        audioTrack?.release()
        audioTrack = null
        playbackSharesCaptureSession = false
        if (restoreRouting) restoreRoutingIfIdleLocked()
    }

    private fun processingState(): Map<String, Any> = synchronized(lock) {
        mapOf(
            "duplexEngine" to true,
            "separateInputTransport" to true,
            "acousticEchoCancelerAvailable" to AcousticEchoCanceler.isAvailable(),
            "acousticEchoCancelerEnabled" to
                runCatching { acousticEchoCanceler?.enabled == true }.getOrDefault(false),
            "noiseSuppressorEnabled" to
                runCatching { noiseSuppressor?.enabled == true }.getOrDefault(false),
            "automaticGainControlEnabled" to
                runCatching { automaticGainControl?.enabled == true }.getOrDefault(false),
            "audioModeInCommunication" to
                (audioManager.mode == AudioManager.MODE_IN_COMMUNICATION),
            "captureActive" to
                (audioRecord?.recordingState == AudioRecord.RECORDSTATE_RECORDING),
            "playbackPrepared" to (audioTrack?.state == AudioTrack.STATE_INITIALIZED),
            "playbackSharesCaptureSession" to playbackSharesCaptureSession,
            "inputSampleRate" to inputSampleRate,
            "outputSampleRate" to outputSampleRate,
        )
    }

    fun dispose() {
        captureGeneration.incrementAndGet()
        playbackGeneration.incrementAndGet()
        channel?.setMethodCallHandler(null)
        channel = null
        inputEventChannel?.setStreamHandler(null)
        inputEventChannel = null
        microphoneEventSink = null
        synchronized(lock) {
            releaseRecordLocked(restoreRouting = false)
            releaseTrackLocked(restoreRouting = false)
            restoreCommunicationRoutingLocked()
        }
        captureExecutor.shutdownNow()
        playbackExecutor.shutdownNow()
    }
}
