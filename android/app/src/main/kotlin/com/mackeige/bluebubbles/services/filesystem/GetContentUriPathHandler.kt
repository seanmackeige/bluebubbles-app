package com.mackeige.bluebubbles.services.filesystem

import android.content.Context
import android.net.Uri
import com.mackeige.bluebubbles.models.MethodCallHandlerImpl
import com.mackeige.bluebubbles.utils.FilesystemUtils
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/// Fetches the actual path of a shared item with a content-uri path
class GetContentUriPathHandler: MethodCallHandlerImpl() {
    companion object {
        const val tag = "get-content-uri-path"
    }

    override fun handleMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
        context: Context
    ) {
        val uri: String = call.argument("uri")!!
        result.success(FilesystemUtils.getAbsolutePath(context, Uri.parse(uri)))
    }
}