package com.example.tunio_radio_player

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import android.os.Build

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        Log.d("BootReceiver", "Received broadcast: ${intent.action}")
        
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            "android.intent.action.QUICKBOOT_POWERON",
            "android.intent.action.MY_PACKAGE_REPLACED",
            "android.intent.action.PACKAGE_REPLACED" -> {
                
                Log.d("BootReceiver", "Boot completed detected, checking settings...")
                
                val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                val apiKey = prefs.getString("flutter.api_key", "")
                val autoStartEnabled = prefs.getBoolean("flutter.auto_start_enabled", true)
                
                Log.d("BootReceiver", "API Key exists: ${!apiKey.isNullOrEmpty()}, Auto-start enabled: $autoStartEnabled")
                
                if (!apiKey.isNullOrEmpty() && autoStartEnabled) {
                    // Увеличиваем задержку для более стабильного запуска
                    val delay = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) 10000L else 5000L
                    
                    android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                        Log.d("BootReceiver", "Attempting to start MainActivity...")
                        
                        val appIntent = Intent(context, MainActivity::class.java)
                        appIntent.addFlags(
                            Intent.FLAG_ACTIVITY_NEW_TASK or 
                            Intent.FLAG_ACTIVITY_CLEAR_TOP or
                            Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED or
                            Intent.FLAG_ACTIVITY_SINGLE_TOP
                        )
                        appIntent.putExtra("auto_start", true)
                        appIntent.putExtra("boot_start", true)
                        
                        try {
                            context.startActivity(appIntent)
                            Log.d("BootReceiver", "Successfully started MainActivity")
                        } catch (e: Exception) {
                            Log.e("BootReceiver", "Failed to start app: ${e.message}", e)
                        }
                    }, delay)
                } else {
                    Log.d("BootReceiver", "Auto-start conditions not met")
                }
            }
        }
    }
} 