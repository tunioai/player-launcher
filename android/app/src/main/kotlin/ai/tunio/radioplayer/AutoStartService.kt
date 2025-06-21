package ai.tunio.radioplayer

import android.app.Service
import android.content.Intent
import android.os.IBinder
import android.util.Log
import android.content.Context

class AutoStartService : Service() {
    
    override fun onBind(intent: Intent?): IBinder? {
        return null
    }
    
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d("AutoStartService", "Service started")
        
        val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val apiKey = prefs.getString("flutter.api_key", "")
        val autoStartEnabled = prefs.getBoolean("flutter.auto_start_enabled", true)
        
        if (!apiKey.isNullOrEmpty() && autoStartEnabled) {
            Log.d("AutoStartService", "Starting MainActivity from service")
            
            val appIntent = Intent(this, MainActivity::class.java)
            appIntent.addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or 
                Intent.FLAG_ACTIVITY_CLEAR_TOP or
                Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED or
                Intent.FLAG_ACTIVITY_SINGLE_TOP
            )
            appIntent.putExtra("auto_start", true)
            appIntent.putExtra("service_start", true)
            
            try {
                startActivity(appIntent)
                Log.d("AutoStartService", "Successfully started MainActivity from service")
            } catch (e: Exception) {
                Log.e("AutoStartService", "Failed to start MainActivity from service: ${e.message}", e)
            }
        }
        
        stopSelf()
        return START_NOT_STICKY
    }
} 