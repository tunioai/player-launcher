package com.example.tunio_radio_player

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import android.os.Build
import android.os.Handler
import android.os.Looper

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
                    startAppWithMultipleMethods(context)
                } else {
                    Log.d("BootReceiver", "Auto-start conditions not met")
                }
            }
        }
    }
    
    private fun startAppWithMultipleMethods(context: Context) {
        // Увеличенная задержка для TV-приставок
        val delay = when {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q -> 20000L // Android 10+
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.O -> 15000L // Android 8+
            else -> 10000L
        }
        
        Log.d("BootReceiver", "Starting app with ${delay}ms delay")
        
        Handler(Looper.getMainLooper()).postDelayed({
            Log.d("BootReceiver", "Attempting multiple start methods...")
            
            // Метод 1: Через сервис (работает лучше на большинстве устройств)
            tryStartViaService(context)
            
            // Метод 2: Прямой запуск активити с задержкой
            Handler(Looper.getMainLooper()).postDelayed({
                tryDirectActivityStart(context)
            }, 2000L)
            
            // Метод 3: Запасной вариант с дополнительными флагами
            Handler(Looper.getMainLooper()).postDelayed({
                tryFallbackStart(context)
            }, 5000L)
            
        }, delay)
    }
    
    private fun tryStartViaService(context: Context) {
        try {
            Log.d("BootReceiver", "Trying service method...")
            val serviceIntent = Intent(context, AutoStartService::class.java)
            context.startService(serviceIntent)
            Log.d("BootReceiver", "Service started successfully")
        } catch (e: Exception) {
            Log.e("BootReceiver", "Service start failed: ${e.message}")
        }
    }
    
    private fun tryDirectActivityStart(context: Context) {
        try {
            Log.d("BootReceiver", "Trying direct activity start...")
            val appIntent = Intent(context, MainActivity::class.java)
            appIntent.addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or 
                Intent.FLAG_ACTIVITY_CLEAR_TOP or
                Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED or
                Intent.FLAG_ACTIVITY_SINGLE_TOP or
                Intent.FLAG_ACTIVITY_BROUGHT_TO_FRONT
            )
            appIntent.putExtra("auto_start", true)
            appIntent.putExtra("boot_start", true)
            
            context.startActivity(appIntent)
            Log.d("BootReceiver", "Direct activity start successful")
        } catch (e: Exception) {
            Log.e("BootReceiver", "Direct activity start failed: ${e.message}")
        }
    }
    
    private fun tryFallbackStart(context: Context) {
        try {
            Log.d("BootReceiver", "Trying fallback start method...")
            val packageManager = context.packageManager
            val launchIntent = packageManager.getLaunchIntentForPackage(context.packageName)
            
            if (launchIntent != null) {
                launchIntent.addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED
                )
                launchIntent.putExtra("auto_start", true)
                launchIntent.putExtra("fallback_start", true)
                
                context.startActivity(launchIntent)
                Log.d("BootReceiver", "Fallback start successful")
            }
        } catch (e: Exception) {
            Log.e("BootReceiver", "Fallback start failed: ${e.message}")
        }
    }
} 