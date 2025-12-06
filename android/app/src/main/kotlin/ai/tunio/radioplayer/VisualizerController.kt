package ai.tunio.radioplayer

import android.app.Activity
import android.content.Intent
import android.util.Log
import io.flutter.plugin.common.MethodChannel

object VisualizerController {
    private const val TAG = "VisualizerController"

    var channel: MethodChannel? = null
    var currentActivity: VisualizerActivity? = null

    fun open(host: Activity, url: String) {
        val intent = Intent(host, VisualizerActivity::class.java).apply {
            putExtra(VisualizerActivity.EXTRA_URL, url)
            addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        host.startActivity(intent)
    }

    fun update(script: String) {
        val activity = currentActivity
        if (activity == null) {
            Log.w(TAG, "Unable to send script, activity is null")
            return
        }
        activity.runOnUiThread {
            activity.runJavaScript(script)
        }
    }

    fun close() {
        val activity = currentActivity ?: return
        activity.runOnUiThread {
            if (!activity.isFinishing) {
                activity.finish()
            }
        }
    }

    fun notifyReady() {
        channel?.invokeMethod("visualizerReady", null)
    }

    fun notifyClosed() {
        channel?.invokeMethod("visualizerClosed", null)
    }

    fun notifyError(message: String) {
        channel?.invokeMethod("visualizerError", message)
    }
}
