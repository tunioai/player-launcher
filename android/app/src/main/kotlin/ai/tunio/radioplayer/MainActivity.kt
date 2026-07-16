package ai.tunio.radioplayer

import android.annotation.SuppressLint
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import android.view.WindowManager
import androidx.core.content.FileProvider
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

// AudioServiceActivity (a thin FlutterActivity subclass) is required by
// audio_service / just_audio_background so JustAudioBackground.init() can attach
// to this activity's FlutterEngine. Without it init() throws and main() aborts
// before runApp(), leaving a black screen.
class MainActivity: AudioServiceActivity() {
    private val CHANNEL = "com.example.tunio_radio_player/autostart"
    private val VISUALIZER_CHANNEL = "ai.tunio/visualizer"
    private val UPDATER_CHANNEL = "ai.tunio/updater"
    
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        
        handleAutoStart()
    }
    
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleAutoStart()
    }

    private fun handleAutoStart() {
        val intent = getIntent()
        val isAutoStart = intent.getBooleanExtra("auto_start", false)
        val isBootStart = intent.getBooleanExtra("boot_start", false)
        val isServiceStart = intent.getBooleanExtra("service_start", false)
        val isHomeAction = Intent.ACTION_MAIN == intent.action && 
                          intent.hasCategory(Intent.CATEGORY_HOME)
        
        if (isAutoStart || isHomeAction) {
            Log.d("MainActivity", "Auto-start or Home launch detected - Boot: $isBootStart, Service: $isServiceStart, Home: $isHomeAction")
            
            // Settings for fullscreen mode
            window.addFlags(
                WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD or
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
            )
            
            // Hide system elements for TV mode
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                window.insetsController?.let { controller ->
                    controller.hide(android.view.WindowInsets.Type.statusBars())
                    controller.hide(android.view.WindowInsets.Type.navigationBars())
                    controller.systemBarsBehavior = 
                        android.view.WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                }
            } else {
                @Suppress("DEPRECATION")
                window.decorView.systemUiVisibility = (
                    android.view.View.SYSTEM_UI_FLAG_FULLSCREEN or
                    android.view.View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
                    android.view.View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                )
            }
        }
    }
    
    private fun isIgnoringBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        return try {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            pm.isIgnoringBatteryOptimizations(packageName)
        } catch (e: Exception) {
            Log.e("MainActivity", "isIgnoringBatteryOptimizations failed: ${e.message}")
            true
        }
    }

    // Ask the user to exempt the app from battery optimization so the OS does
    // not freeze/Doze the process in the background (needed for reliable
    // background failover). No-op if already exempt.
    @SuppressLint("BatteryLife")
    private fun requestIgnoreBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        if (isIgnoringBatteryOptimizations()) return true
        try {
            val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                data = Uri.parse("package:$packageName")
            }
            startActivity(intent)
            return true
        } catch (e: Exception) {
            Log.w("MainActivity", "Direct battery-opt request failed: ${e.message}")
        }
        return try {
            startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
            true
        } catch (e: Exception) {
            Log.e("MainActivity", "Battery-opt settings fallback failed: ${e.message}")
            false
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "isAutoStarted" -> {
                    val intent = getIntent()
                    val isAutoStart = intent.getBooleanExtra("auto_start", false)
                    result.success(isAutoStart)
                }
                "isIgnoringBatteryOptimizations" -> {
                    result.success(isIgnoringBatteryOptimizations())
                }
                "requestIgnoreBatteryOptimizations" -> {
                    result.success(requestIgnoreBatteryOptimizations())
                }

                else -> result.notImplemented()
            }
        }

        val visualizerChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            VISUALIZER_CHANNEL,
        )
        VisualizerController.channel = visualizerChannel
        visualizerChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "openVisualizer" -> {
                    val url = call.argument<String>("url")
                    val lowPerformanceMode = call.argument<Boolean>("lowPerformanceMode") ?: false
                    if (url.isNullOrEmpty()) {
                        result.error("INVALID_URL", "Visualizer URL is missing", null)
                    } else {
                        VisualizerController.open(this, url, lowPerformanceMode)
                        result.success(null)
                    }
                }
                "updateVisualizer" -> {
                    val script = call.argument<String>("script")
                    if (script.isNullOrEmpty()) {
                        result.error("INVALID_SCRIPT", "JavaScript payload is empty", null)
                    } else {
                        VisualizerController.update(script)
                        result.success(null)
                    }
                }
                "closeVisualizer" -> {
                    VisualizerController.close()
                    result.success(null)
                }
                "getScreenCacheInfo" -> {
                    val appContext = applicationContext
                    Thread {
                        val info = try {
                            VisualizerActivity.collectScreenCacheInfo(appContext)
                        } catch (error: Throwable) {
                            null
                        }
                        runOnUiThread {
                            if (info != null) {
                                result.success(info)
                            } else {
                                result.error(
                                    "CACHE_INFO_FAILED",
                                    "Failed to read screen cache",
                                    null,
                                )
                            }
                        }
                    }.start()
                }
                "clearScreenCache" -> {
                    val appContext = applicationContext
                    Thread {
                        val ok = try {
                            VisualizerActivity.clearScreenCache(appContext)
                            true
                        } catch (error: Throwable) {
                            false
                        }
                        runOnUiThread {
                            if (ok) {
                                result.success(null)
                            } else {
                                result.error(
                                    "CACHE_CLEAR_FAILED",
                                    "Failed to clear screen cache",
                                    null,
                                )
                            }
                        }
                    }.start()
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, UPDATER_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "canRequestPackageInstalls" -> {
                        val canInstall = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            packageManager.canRequestPackageInstalls()
                        } else {
                            true
                        }
                        result.success(canInstall)
                    }
                    "openUnknownAppSourcesSettings" -> {
                        val intent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).apply {
                            data = Uri.parse("package:$packageName")
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        startActivity(intent)
                        result.success(null)
                    }
                    "installApk" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrBlank()) {
                            result.error("INVALID_PATH", "APK path is missing", null)
                            return@setMethodCallHandler
                        }

                        val apkFile = File(path)
                        if (!apkFile.exists()) {
                            result.error("FILE_NOT_FOUND", "APK file not found: $path", null)
                            return@setMethodCallHandler
                        }

                        val apkUri = FileProvider.getUriForFile(
                            this,
                            "${packageName}.fileprovider",
                            apkFile
                        )

                        val installIntent = Intent(Intent.ACTION_INSTALL_PACKAGE).apply {
                            data = apkUri
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }

                        try {
                            startActivity(installIntent)
                            result.success(null)
                        } catch (e: ActivityNotFoundException) {
                            val fallbackIntent = Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(apkUri, "application/vnd.android.package-archive")
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(fallbackIntent)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("INSTALL_FAILED", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
