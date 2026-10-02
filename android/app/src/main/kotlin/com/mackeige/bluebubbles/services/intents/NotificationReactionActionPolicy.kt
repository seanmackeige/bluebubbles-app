package com.mackeige.bluebubbles.services.intents

/**
 * Fail-closed contract for the native notification reaction shortcut.
 *
 * Logical conversations must route reactions through Dart's revision-bound
 * admission path, never the legacy native physical-chat HTTP shortcut. The
 * explicit contract also makes notification actions created by an older APK
 * inert after an in-place upgrade.
 */
object NotificationReactionActionPolicy {
    const val CURRENT_CONTRACT = "NATIVE_REACTION_ACTION_V2_PHYSICAL_ONLY"
    const val CURRENT_INTENT_ACTION =
        "com.mackeige.bluebubbles.action.NATIVE_REACTION_V2_PHYSICAL_ONLY"

    @JvmStatic
    fun mayDispatch(
        contract: String?,
        intentAction: String?,
        conversationKey: String?,
        physicalChatGuid: String?
    ): Boolean =
        contract == CURRENT_CONTRACT &&
            intentAction == CURRENT_INTENT_ACTION &&
            !physicalChatGuid.isNullOrEmpty() &&
            conversationKey == physicalChatGuid
}
