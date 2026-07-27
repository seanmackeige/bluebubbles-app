package com.mackeige.bluebubbles.services.foreground

import android.os.Build
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.widget.Toast
import com.mackeige.bluebubbles.Constants
import com.mackeige.bluebubbles.services.foreground.SocketIOForegroundService
import com.mackeige.bluebubbles.utils.PersistentLog

class ForegroundServiceBroadcastReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        PersistentLog.d(context, Constants.logTag, "Received Foreground Service Broadcast");

        if (context != null) {
            val intent = Intent(context, SocketIOForegroundService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent);
            } else {
                context.startService(intent);
            }
        }
    }
}