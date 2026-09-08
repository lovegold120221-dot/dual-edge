package ai.eburon.dualtranslate

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var livePcmAudio: LivePcmAudioChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        livePcmAudio = LivePcmAudioChannel(this, flutterEngine).also { it.register() }
    }

    override fun onDestroy() {
        livePcmAudio?.dispose()
        livePcmAudio = null
        super.onDestroy()
    }
}
