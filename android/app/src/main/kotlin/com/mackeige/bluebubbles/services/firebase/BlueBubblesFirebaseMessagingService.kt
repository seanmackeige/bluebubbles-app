package com.mackeige.bluebubbles.services.firebase

import android.content.Intent
import androidx.core.os.bundleOf
import com.mackeige.bluebubbles.Constants
import com.mackeige.bluebubbles.services.backend_ui_interop.DartWorkManager
import com.mackeige.bluebubbles.utils.PersistentLog
import com.mackeige.bluebubbles.utils.Utils
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import io.flutter.plugin.common.MethodChannel

class BlueBubblesFirebaseMessagingService: FirebaseMessagingService() {
    override fun onCreate() {
        super.onCreate()
        PersistentLog.d(applicationContext, Constants.logTag, "FCM service created")
    }

    override fun onMessageReceived(message: RemoteMessage) {
        super.onMessageReceived(message)
        val type = message.data["type"] ?: return
        PersistentLog.d(applicationContext, Constants.logTag, "Received new message of type $type from FCM...")
        DartWorkManager.createWorker(applicationContext, type, HashMap(message.data)) {}

        // check if the user configured "Send Events to Tasker"
        val prefs = applicationContext.getSharedPreferences("FlutterSharedPreferences", 0)
        if (prefs.getBoolean("sendEventsToTasker", false)) {
            Utils.getServerUrl(applicationContext, object : MethodChannel.Result {
                override fun success(result: Any?) {
                    PersistentLog.d(applicationContext, Constants.logTag, "Got URL: $result - sending to Tasker...")
                    val intent = Intent()
                    intent.setAction("net.dinglisch.android.taskerm.BB_EVENT")
                    intent.putExtra("url", result.toString())
                    intent.putExtra("event", type)
                    intent.putExtras(bundleOf(*message.data.toList().toTypedArray()))
                    applicationContext.sendBroadcast(intent)
                }

                override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {}
                override fun notImplemented() {}
            })
        }
    }
}