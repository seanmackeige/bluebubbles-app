package com.mackeige.bluebubbles.services.system

import android.content.Context
import android.content.Intent
import androidx.core.app.Person
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import com.mackeige.bluebubbles.Constants
import com.mackeige.bluebubbles.MainActivity
import com.mackeige.bluebubbles.models.MethodCallHandlerImpl
import com.mackeige.bluebubbles.utils.PersistentLog
import com.mackeige.bluebubbles.utils.Utils
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/// Create android share sheet targets
class PushShareTargetsHandler: MethodCallHandlerImpl() {
    companion object {
        const val tag = "push-share-targets"
    }

    override fun handleMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
        context: Context
    ) {
        val cleanupIds: List<String> = call.argument<List<String>>("remove_shortcut_ids") ?: emptyList()
        val protectedIds: List<String> = call.argument<List<String>>("protected_shortcut_ids") ?: emptyList()
        removeShareTargets(context, cleanupIds, protectedIds)
        val name: String? = call.argument("title")
        val guid: String? = call.argument("guid")
        if (name == null || guid == null) {
            result.success(null)
            return
        }
        val icon: ByteArray? = call.argument("icon")
        val conversationKey: String = call.argument<String>("conversation_key") ?: guid
        val legacyPhysicalGuids: List<String> = call.argument<List<String>>("legacy_physical_guids") ?: emptyList()
        pushShareTarget(context, name, guid, icon, conversationKey, legacyPhysicalGuids)
        result.success(null)
    }

    fun removeShareTargets(
        context: Context,
        candidateIds: List<String>,
        protectedIds: List<String> = emptyList()
    ) {
        val staleShortcutIds = ShareTargetCleanupPolicy.staleShortcutIds(candidateIds, protectedIds)
        if (staleShortcutIds.isEmpty()) return
        ShortcutManagerCompat.removeDynamicShortcuts(context, staleShortcutIds)
        ShortcutManagerCompat.removeLongLivedShortcuts(context, staleShortcutIds)
    }


    fun pushShareTarget(
        context: Context,
        name: String,
        guid: String,
        icon: ByteArray?,
        shortcutId: String = guid,
        legacyPhysicalGuids: List<String> = emptyList()
    ) {
        val adaptiveIcon = if ((icon?.size ?: 0) == 0) null else Utils.getAdaptiveIconFromByteArray(icon!!)

        PersistentLog.d(context, Constants.logTag, "Creating intent for shortcut with name $name")
        val contactCategories = setOf(Constants.categoryTextShareTarget)
        val launcherIntent = Intent(context, MainActivity::class.java)
            .putExtra("chatGuid", guid)
            .putExtra("conversationKey", shortcutId)
            .putExtra("sourceChatGuid", guid)
            .putExtra("bubble", false)
            .setAction(Intent.ACTION_DEFAULT)
        val person = Person.Builder().setName(name)
        if (adaptiveIcon != null) {
            person.setIcon(adaptiveIcon)
        }

        removeShareTargets(context, legacyPhysicalGuids, listOf(shortcutId))

        PersistentLog.d(context, Constants.logTag, "Creating and pushing shortcut for $name")
        val shortcut = ShortcutInfoCompat.Builder(context, shortcutId)
            .setShortLabel(name)
            .setIntent(launcherIntent)
            .setCategories(contactCategories)
            .setLongLived(true)
            .setIsConversation()
            .setPerson(person.build())
        if (adaptiveIcon != null) {
            shortcut.setIcon(adaptiveIcon)
        }

        ShortcutManagerCompat.pushDynamicShortcut(context, shortcut.build())
    }
}