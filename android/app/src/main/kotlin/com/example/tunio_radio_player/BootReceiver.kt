package com.example.tunio_radio_player

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (Intent.ACTION_BOOT_COMPLETED == intent.action ||
            "android.intent.action.QUICKBOOT_POWERON" == intent.action
        ) {
            val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            val apiKey = prefs.getString("flutter.api_key", "")
            
            if (!apiKey.isNullOrEmpty()) {
                val appIntent = Intent(context, MainActivity::class.java)
                appIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                appIntent.putExtra("auto_start", true)
                context.startActivity(appIntent)
            }
        }
    }
} 