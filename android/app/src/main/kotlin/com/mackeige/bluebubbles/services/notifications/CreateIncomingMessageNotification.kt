package com.mackeige.bluebubbles.services.notifications

import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import androidx.core.app.NotificationCompat
import androidx.core.app.Person
import androidx.core.app.RemoteInput
import androidx.core.graphics.drawable.IconCompat
import com.mackeige.bluebubbles.BubbleActivity
import com.mackeige.bluebubbles.Constants
import com.mackeige.bluebubbles.MainActivity
import com.mackeige.bluebubbles.R
import com.mackeige.bluebubbles.models.MethodCallHandlerImpl
import com.mackeige.bluebubbles.services.intents.InternalIntentReceiver
import com.mackeige.bluebubbles.services.intents.NotificationReactionActionPolicy
import com.mackeige.bluebubbles.services.system.PushShareTargetsHandler
import com.mackeige.bluebubbles.utils.Utils
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class CreateIncomingMessageNotification: MethodCallHandlerImpl() {
    companion object {
        const val tag = "create-incoming-message-notification"
        private val notificationLock = Any()
    }

    override fun handleMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
        context: Context
    ) {
        // channel details
        val channelId: String = call.argument("channel_id")!!
        // chat details
        val chatGuid: String = call.argument("chat_guid")!!
        val conversationKey: String = call.argument<String>("conversation_key") ?: chatGuid
        val sourceChatGuid: String = call.argument<String>("source_chat_guid") ?: chatGuid
        val notificationTag: String = call.argument<String>("notification_tag") ?: Constants.newMessageNotificationTag
        val chatTitle: String = call.argument("chat_title")!!
        val chatIsGroup: Boolean = call.argument("chat_is_group")!!
        val chatIcon: ByteArray? = call.argument("chat_icon")
        val chatBitmap = if ((chatIcon?.size ?: 0) == 0) null else Utils.getAdaptiveIconFromByteArray(chatIcon!!)
        // message details
        val messageText: String = call.argument("message_text")!!
        val messageGuid: String = call.argument("message_guid")!!
        val messageDate: Long = call.argument("message_date")!!
        val messageIsFromMe: Boolean = call.argument("message_is_from_me")!!
        // contact details
        val contactName: String = call.argument("contact_name")!!
        val contactIcon: ByteArray? = call.argument("contact_avatar")
        val contactBitmap = if ((contactIcon?.size ?: 0) == 0) null else Utils.getAdaptiveIconFromByteArray(contactIcon!!)
        // reaction settings
        val showReactionAction: Boolean = call.argument("show_reaction_action") ?: false
        val reactionType: String = call.argument("reaction_type") ?: "like"
        val allowNativeReactionAction = showReactionAction &&
            NotificationReactionActionPolicy.mayDispatch(
                NotificationReactionActionPolicy.CURRENT_CONTRACT,
                NotificationReactionActionPolicy.CURRENT_INTENT_ACTION,
                conversationKey,
                chatGuid
            )
        val mutationDecision = NotificationMutationPolicy.decide(
            allowMutatingActions = call.argument<Boolean>("allow_mutating_actions") ?: true,
            showReactionAction = allowNativeReactionAction,
        )

        // calculate a notification ID based on the chat database ID
        val notificationId: Int = call.argument("chat_id")!!

        val notificationManager = context.getSystemService(NotificationManager::class.java)
        
        // Serialize inspection, style merge, and notify as one native critical
        // section. Exact duplicate events and distinct concurrent messages
        // cannot race between activeNotifications and notify().
        synchronized(notificationLock) {
            val conversationNotification = notificationManager.activeNotifications.lastOrNull {
                (it.notification.extras.getString("conversationKey")
                    ?: it.notification.extras.getString("chatGuid")) == conversationKey
            }
            val previousExtras = conversationNotification?.notification?.extras
            val historyDecision = NotificationEventHistoryPolicy.decide(
                previousExtras?.getStringArrayList(NotificationEventHistoryPolicy.EXTRA_KEY),
                previousExtras?.getString("sourceChatGuid") ?: previousExtras?.getString("chatGuid"),
                previousExtras?.getString("messageGuid"),
                sourceChatGuid,
                messageGuid
            )
            if (historyDecision.admission != NotificationEventHistoryPolicy.Admission.ADMIT) {
                return result.success(null)
            }

            // this is used to copy the style, since the notification already exists
            val chatNotification = conversationNotification?.takeIf {
                it.notification.extras.getString("channelId") == channelId
            }

        // build the sender object and push the share target again
        val sender = Person.Builder()
            .setName(contactName)
            .setIcon(contactBitmap)
            .setImportant(true)
            .build()
        if (mutationDecision.shareTarget) {
            PushShareTargetsHandler().pushShareTarget(context, chatTitle, chatGuid, chatIcon, conversationKey)
        }

        // get or create a messaging style
        val style = if (chatNotification != null) {
            NotificationCompat.MessagingStyle.extractMessagingStyleFromNotification(chatNotification.notification)
                ?: NotificationCompat.MessagingStyle(Person.Builder().setName("You").build())
        } else {
            NotificationCompat.MessagingStyle(Person.Builder().setName("You").build())
        }
        if (chatIsGroup) {
            style.isGroupConversation = true
            style.conversationTitle = chatTitle
        }
        // add the new message to the style
        style.addMessage(NotificationCompat.MessagingStyle.Message(
            messageText,
            messageDate,
            sender
        ))

        // create a bundle for extra info
        val extras = Bundle()
        extras.putString("chatGuid", chatGuid)
        extras.putString("conversationKey", conversationKey)
        extras.putString("sourceChatGuid", sourceChatGuid)
        extras.putString("messageGuid", messageGuid)
        extras.putString("messageEventHistoryContract", NotificationEventHistoryPolicy.CONTRACT)
        extras.putString("notificationMutationContract", NotificationMutationPolicy.CONTRACT)
        extras.putBoolean("allowMutatingActions", mutationDecision.markRead || mutationDecision.reply)
        extras.putStringArrayList(
            NotificationEventHistoryPolicy.EXTRA_KEY,
            ArrayList(historyDecision.encodedHistory)
        )
        extras.putString("reactionActionContract", NotificationReactionActionPolicy.CURRENT_CONTRACT)
        extras.putString("channelId", channelId)
        extras.putString("tag", notificationTag)
        extras.putBoolean("reactionSent", false) // Track if reaction has been sent

        // intent to open the conversation in-app
        val openConversationIntent = PendingIntent.getActivity(
            context,
            notificationId + Constants.pendingIntentOpenChatOffset,
            Intent(context, MainActivity::class.java)
                .putExtras(extras)
                .putExtra("notificationId", notificationId)
                .putExtra("bubble", false)
                .setData(Uri.parse("bluebubbles://notification/${Uri.encode(conversationKey)}/open"))
                .setType("OpenChat"),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        // intent to swipe away the notification
        val deleteNotificationIntent = PendingIntent.getBroadcast(
            context,
            notificationId + Constants.pendingIntentDeleteNotificationOffset,
            Intent(context, InternalIntentReceiver::class.java)
                .putExtras(extras)
                .putExtra("notificationId", notificationId)
                .setData(Uri.parse("bluebubbles://notification/${Uri.encode(conversationKey)}/delete"))
                .setType("DeleteNotification"),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        // intent and action for 'mark as read'
        val markAsReadIntent = PendingIntent.getBroadcast(
            context,
            notificationId + Constants.pendingIntentMarkReadOffset,
            Intent(context, InternalIntentReceiver::class.java)
                .putExtras(extras)
                .putExtra("notificationId", notificationId)
                .setData(Uri.parse("bluebubbles://notification/${Uri.encode(conversationKey)}/read"))
                .setType("MarkChatRead"),
            PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val markAsReadAction = NotificationCompat.Action.Builder(0, "Mark As Read", markAsReadIntent)
            .setSemanticAction(NotificationCompat.Action.SEMANTIC_ACTION_MARK_AS_READ)
            .setShowsUserInterface(false)
            .build()

        // intent and action for quick reply
        val replyIntent = PendingIntent.getBroadcast(
            context,
            notificationId,
            Intent(context, InternalIntentReceiver::class.java)
                .putExtras(extras)
                .putExtra("notificationId", notificationId)
                .setData(Uri.parse("bluebubbles://notification/${Uri.encode(conversationKey)}/reply"))
                .setType("ReplyChat"),
            PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val replyAction = NotificationCompat.Action.Builder(0, "Reply", replyIntent)
            .setSemanticAction(NotificationCompat.Action.SEMANTIC_ACTION_REPLY)
            .setShowsUserInterface(false)
            .setAllowGeneratedReplies(true)
            .extend(NotificationCompat.Action.WearableExtender().setHintDisplayActionInline(true))
            .addRemoteInput(RemoteInput.Builder("text_reply").setLabel("Reply").build())
            .build()

        // intent and action for 'like'
        val likeIntent = PendingIntent.getBroadcast(
            context,
            notificationId + 1, // offset by 1 to avoid conflicts
            Intent(context, InternalIntentReceiver::class.java)
                .putExtras(extras)
                .putExtra("notificationId", notificationId)
                .putExtra("messageText", messageText)
                .putExtra("reactionType", reactionType)
                .setAction(NotificationReactionActionPolicy.CURRENT_INTENT_ACTION)
                .setData(Uri.parse("bluebubbles://notification/${Uri.encode(conversationKey)}/reaction"))
                .setType("LikeMessage"),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val likeActionTitle = if (reactionType == "love") "Love" else "Like"
        val likeAction = NotificationCompat.Action.Builder(0, likeActionTitle, likeIntent)
            .setSemanticAction(NotificationCompat.Action.SEMANTIC_ACTION_THUMBS_UP)
            .setShowsUserInterface(false)
            .build()

        // intent for bubbling (create it even if not used, for future compatibility)
        val bubbleIntent = PendingIntent.getActivity(
            context,
            notificationId + Constants.pendingIntentOpenBubbleOffset,
            Intent(context, BubbleActivity::class.java)
                .putExtras(extras)
                .putExtra("notificationId", notificationId)
                .putExtra("bubble", true)
                .setData(Uri.parse("bluebubbles://notification/${Uri.encode(conversationKey)}/bubble"))
                .setType("OpenChat"),
            PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        // Build the notification
        val notificationBuilder = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(R.mipmap.ic_stat_icon)
            .setGroup(Constants.notificationGroupKey)
            .setGroupAlertBehavior(NotificationCompat.GROUP_ALERT_CHILDREN)
            .setOnlyAlertOnce(messageIsFromMe)
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setContentIntent(openConversationIntent)
            .setDeleteIntent(deleteNotificationIntent)
            .setStyle(style)
            .setAllowSystemGeneratedContextualActions(mutationDecision.reply)
            .setColor(4888294)
            .addPerson(sender)
            .addExtras(extras)
        if (mutationDecision.markRead) {
            notificationBuilder.addAction(markAsReadAction)
        }
        if (mutationDecision.reply) {
            notificationBuilder.addAction(replyAction)
        }

        // Conditionally add reaction action if enabled
        if (mutationDecision.reaction) {
            notificationBuilder.addAction(likeAction)
        }

        // Build wearable extender
        val wearableExtender = NotificationCompat.WearableExtender()
        if (mutationDecision.markRead) wearableExtender.addAction(markAsReadAction)
        if (mutationDecision.reply) wearableExtender.addAction(replyAction)
        if (mutationDecision.reaction) {
            wearableExtender.addAction(likeAction)
        }
        notificationBuilder.extend(wearableExtender)

        // Only set bubble metadata on Android 11+ (API 29+) where it's supported
        if (mutationDecision.bubble && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val bubbleMetadata = NotificationCompat.BubbleMetadata.Builder(bubbleIntent, chatBitmap ?: IconCompat.createWithResource(context, R.mipmap.ic_stat_icon))
                .setDesiredHeight(600)
                .setDeleteIntent(deleteNotificationIntent)
                .build()
            notificationBuilder.setBubbleMetadata(bubbleMetadata)
        }
        
        // Only set shortcut ID on API 29+ where dynamic shortcuts are better supported
        if (mutationDecision.shortcut && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            notificationBuilder.setShortcutId(conversationKey)
        }

        // intent to open the main app
        val openSummaryIntent = PendingIntent.getActivity(
            context,
            0,
            Intent(context, MainActivity::class.java)
                .putExtra("chatGuid", "-1")
                .putExtra("notificationId", 0)
                .putExtra("bubble", false)
                .setType("OpenSummary"),
            PendingIntent.FLAG_IMMUTABLE
        )

        val summaryNotificationBuilder = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(R.mipmap.ic_stat_icon)
            .setGroup(Constants.notificationGroupKey)
            .setGroupSummary(true)
            .setGroupAlertBehavior(NotificationCompat.GROUP_ALERT_CHILDREN)
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setContentIntent(openSummaryIntent)
            .setColor(4888294)

        notificationManager.notify(Constants.newMessageNotificationTag, 0, summaryNotificationBuilder.build())
        notificationManager.notify(notificationTag, notificationId, notificationBuilder.build())
        result.success(null)
        }
    }
}