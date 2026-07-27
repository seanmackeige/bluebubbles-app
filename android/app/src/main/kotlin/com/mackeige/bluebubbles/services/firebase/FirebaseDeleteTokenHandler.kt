package com.mackeige.bluebubbles.services.firebase

import android.content.Context
import com.mackeige.bluebubbles.Constants
import com.mackeige.bluebubbles.models.MethodCallHandlerImpl
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class FirebaseDeleteTokenHandler: MethodCallHandlerImpl() {
    companion object {
        const val tag: String = "firebase-delete-token"
    }

    override fun handleMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
        context: Context
    ) {
        FirebaseCloudMessagingTokenHandler().deleteToken(context, result)
    }
}