package ai.tunio.radioplayer

import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.example.tunio_radio_player/autostart"
    
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
    
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "isAutoStarted" -> {
                    val intent = getIntent()
                    val isAutoStart = intent.getBooleanExtra("auto_start", false)
                    result.success(isAutoStart)
                }
                "requestIgnoreBatteryOptimizations" -> {
                    // This method can be useful for TV set-top boxes
                    result.success(true)
                }

                else -> result.notImplemented()
            }
        }
    }
}

