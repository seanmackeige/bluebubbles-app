package com.mackeige.bluebubbles

class Constants {
    companion object {
        const val logTag: String = "BlueBubblesApp"
        const val methodChannel = "com.mackeige.bluebubbles"
        const val categoryTextShareTarget = "com.mackeige.bluebubbles.directshare.category.TEXT_SHARE_TARGET"
        const val googleDuoPackageName = "com.google.android.apps.tachyon"
        const val newMessageNotificationTag = "com.mackeige.bluebubbles.NEW_MESSAGE_NOTIFICATION"
        const val newFaceTimeNotificationTag = "com.mackeige.bluebubbles.NEW_FACETIME_NOTIFICATION"
        const val notificationGroupKey = "com.mackeige.bluebubbles.NOTIFICATION_GROUP_NEW_MESSAGES"
        const val foregroundServiceNotificationChannel = "com.mackeige.bluebubbles.foreground_service"
        const val foregroundServiceNotificationId = 1
        const val dartWorkerTag = "DartWorker"
        const val pendingIntentOpenChatOffset = 0
        const val pendingIntentMarkReadOffset = 100000
        const val pendingIntentOpenBubbleOffset = 200000
        const val pendingIntentDeleteNotificationOffset = 300000
        const val pendingIntentAnswerFaceTimeOffset = -100000
        const val pendingIntentDeclineFaceTimeOffset = -200000
        const val notificationListenerRequestCode = 1000
        const val dartWorkerNotificationId = 1000000
    }
}

