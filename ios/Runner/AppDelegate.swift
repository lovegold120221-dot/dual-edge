import AVFoundation
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var livePcmAudio: LivePcmAudioChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "DualTranslateLivePcmAudio"
    ) {
      livePcmAudio = LivePcmAudioChannel(messenger: registrar.messenger())
    }
  }
}

private final class LivePcmAudioChannel: NSObject, FlutterStreamHandler {
  private let channel: FlutterMethodChannel
  private let inputChannel: FlutterEventChannel
  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private var outputSampleRate: Int = 24_000
  private var inputSampleRate: Int = 16_000
  private var playerAttached = false
  private var playbackPrepared = false
  private var captureActive = false
  private var microphoneEventSink: FlutterEventSink?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "ai.eburon.translator/live_pcm_v1",
      binaryMessenger: messenger
    )
    inputChannel = FlutterEventChannel(
      name: "ai.eburon.translator/live_pcm_input_v1",
      binaryMessenger: messenger
    )
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    inputChannel.setStreamHandler(self)
  }

  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    microphoneEventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    microphoneEventSink = nil
    return nil
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any]
    switch call.method {
    case "prepare":
      let requestedRate = arguments?["sampleRate"] as? Int ?? 24_000
      do {
        try prepare(sampleRate: requestedRate)
        result(nil)
      } catch {
        result(
          FlutterError(
            code: "PCM_PREPARE_FAILED",
            message: error.localizedDescription,
            details: nil
          )
        )
      }
    case "write":
      guard let data = arguments?["data"] as? FlutterStandardTypedData else {
        result(nil)
        return
      }
      let requestedRate = arguments?["sampleRate"] as? Int ?? 24_000
      do {
        try write(data.data, sampleRate: requestedRate)
        result(nil)
      } catch {
        result(
          FlutterError(
            code: "PCM_WRITE_FAILED",
            message: error.localizedDescription,
            details: nil
          )
        )
      }
    case "startCapture":
      let requestedRate = arguments?["sampleRate"] as? Int ?? 16_000
      do {
        try startCapture(sampleRate: requestedRate)
        result(nil)
      } catch {
        result(
          FlutterError(
            code: "PCM_CAPTURE_FAILED",
            message: error.localizedDescription,
            details: nil
          )
        )
      }
    case "stopCapture":
      stopCapture()
      result(nil)
    case "stopPlayback":
      stopPlayback()
      result(nil)
    case "getProcessingState":
      result(processingState())
    case "stop":
      stopAll()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func prepare(sampleRate requestedRate: Int) throws {
    try configureVoiceSession()

    if !playerAttached {
      engine.attach(player)
      playerAttached = true
    }

    if !playbackPrepared || outputSampleRate != requestedRate {
      if player.isPlaying { player.stop() }
      if engine.isRunning { engine.stop() }
      engine.disconnectNodeOutput(player)

      guard let format = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: Double(requestedRate),
        channels: 1,
        interleaved: true
      ) else {
        throw audioError("Invalid speaker PCM audio format.")
      }

      engine.connect(player, to: engine.mainMixerNode, format: format)
      outputSampleRate = requestedRate
      playbackPrepared = true
    }

    try startEngineIfNeeded()
  }

  private func write(_ data: Data, sampleRate requestedRate: Int) throws {
    guard !data.isEmpty else { return }
    try prepare(sampleRate: requestedRate)
    guard let format = AVAudioFormat(
      commonFormat: .pcmFormatInt16,
      sampleRate: Double(requestedRate),
      channels: 1,
      interleaved: true
    ) else { return }
    let frameCount = AVAudioFrameCount(data.count / MemoryLayout<Int16>.size)
    guard let buffer = AVAudioPCMBuffer(
      pcmFormat: format,
      frameCapacity: frameCount
    ) else { return }
    buffer.frameLength = frameCount
    data.withUnsafeBytes { source in
      if let baseAddress = source.baseAddress,
        let destination = buffer.int16ChannelData?[0]
      {
        memcpy(destination, baseAddress, data.count)
      }
    }
    player.scheduleBuffer(buffer)
    if !player.isPlaying { player.play() }
  }

  private func startCapture(sampleRate requestedRate: Int) throws {
    if captureActive && inputSampleRate == requestedRate { return }
    if captureActive { stopCapture() }

    try prepare(sampleRate: outputSampleRate)

    let inputNode = engine.inputNode
    let sourceFormat = inputNode.inputFormat(forBus: 0)
    guard sourceFormat.sampleRate > 0, sourceFormat.channelCount > 0 else {
      throw audioError("The microphone has no usable input format.")
    }
    guard let targetFormat = AVAudioFormat(
      commonFormat: .pcmFormatInt16,
      sampleRate: Double(requestedRate),
      channels: 1,
      interleaved: true
    ) else {
      throw audioError("Invalid microphone PCM audio format.")
    }
    guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
      throw audioError("The microphone audio format cannot be converted.")
    }
    converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue

    inputNode.installTap(
      onBus: 0,
      bufferSize: 2_048,
      format: sourceFormat
    ) { [weak self] buffer, _ in
      self?.emitMicrophoneData(
        buffer,
        targetFormat: targetFormat,
        converter: converter
      )
    }
    inputSampleRate = requestedRate
    captureActive = true
    try startEngineIfNeeded()
  }

  private func emitMicrophoneData(
    _ buffer: AVAudioPCMBuffer,
    targetFormat: AVAudioFormat,
    converter: AVAudioConverter
  ) {
    let rateRatio = targetFormat.sampleRate / buffer.format.sampleRate
    let capacity = max(
      AVAudioFrameCount(1),
      AVAudioFrameCount(ceil(Double(buffer.frameLength) * rateRatio))
    )
    guard let converted = AVAudioPCMBuffer(
      pcmFormat: targetFormat,
      frameCapacity: capacity
    ) else { return }

    var suppliedInput = false
    var conversionError: NSError?
    let status = converter.convert(
      to: converted,
      error: &conversionError
    ) { _, outputStatus in
      if suppliedInput {
        outputStatus.pointee = .noDataNow
        return nil
      }
      suppliedInput = true
      outputStatus.pointee = .haveData
      return buffer
    }
    guard status != .error,
      conversionError == nil,
      converted.frameLength > 0,
      let samples = converted.int16ChannelData?[0]
    else { return }

    let byteCount = Int(converted.frameLength) * MemoryLayout<Int16>.size
    let data = Data(bytes: samples, count: byteCount)
    DispatchQueue.main.async { [weak self] in
      guard let self, self.captureActive else { return }
      self.microphoneEventSink?(FlutterStandardTypedData(bytes: data))
    }
  }

  private func configureVoiceSession() throws {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(
      .playAndRecord,
      mode: .voiceChat,
      options: [.defaultToSpeaker, .allowBluetoothHFP]
    )
    try session.setPreferredIOBufferDuration(0.01)
    try session.setActive(true)

    let inputNode = engine.inputNode
    // Instantiating both I/O nodes before enabling voice processing ensures
    // AVAudioEngine switches the complete duplex path to Voice Processing I/O.
    _ = engine.outputNode
    if !inputNode.isVoiceProcessingEnabled {
      if engine.isRunning { engine.stop() }
      try inputNode.setVoiceProcessingEnabled(true)
    }
    inputNode.isVoiceProcessingAGCEnabled = true
  }

  private func startEngineIfNeeded() throws {
    guard !engine.isRunning else { return }
    engine.prepare()
    try engine.start()
  }

  private func stopCapture() {
    guard captureActive else { return }
    captureActive = false
    engine.inputNode.removeTap(onBus: 0)
  }

  private func stopPlayback() {
    if player.isPlaying { player.stop() }
    player.reset()
  }

  private func stopAll() {
    stopCapture()
    stopPlayback()
    if engine.isRunning { engine.stop() }
    engine.reset()
    playbackPrepared = false
    try? AVAudioSession.sharedInstance().setActive(
      false,
      options: .notifyOthersOnDeactivation
    )
  }

  private func processingState() -> [String: Any] {
    return [
      "duplexEngine": true,
      "separateInputTransport": true,
      "voiceProcessingEnabled": engine.inputNode.isVoiceProcessingEnabled,
      "outputVoiceProcessingEnabled": engine.outputNode.isVoiceProcessingEnabled,
      "automaticGainControlEnabled": engine.inputNode.isVoiceProcessingAGCEnabled,
      "captureActive": captureActive,
      "playbackPrepared": playbackPrepared,
      "inputSampleRate": inputSampleRate,
      "outputSampleRate": outputSampleRate,
      "sessionMode": AVAudioSession.sharedInstance().mode.rawValue,
    ]
  }

  private func audioError(_ message: String) -> NSError {
    return NSError(
      domain: "DualTranslateAudio",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: message]
    )
  }

  deinit {
    channel.setMethodCallHandler(nil)
    inputChannel.setStreamHandler(nil)
    microphoneEventSink = nil
    stopAll()
  }
}
