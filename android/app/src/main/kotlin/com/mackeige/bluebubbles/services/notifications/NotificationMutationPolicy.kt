package com.mackeige.bluebubbles.services.notifications

/**
 * Closed native action policy for notification identities that remain
 * mutation-protected after candidate reconciliation terminates.
 *
 * A read-only notification may still open or dismiss. It may not expose any
 * provider/local mutation affordance or publish a direct-share shortcut.
 */
object NotificationMutationPolicy {
    const val CONTRACT = "LOGICAL_NOTIFICATION_MUTATION_POLICY_V1_READ_ONLY_TERMINAL"

    data class Decision(
        val markRead: Boolean,
        val reply: Boolean,
        val reaction: Boolean,
        val shareTarget: Boolean,
        val bubble: Boolean,
        val shortcut: Boolean,
    )

    fun decide(
        allowMutatingActions: Boolean,
        showReactionAction: Boolean,
    ): Decision {
        if (!allowMutatingActions) {
            return Decision(
                markRead = false,
                reply = false,
                reaction = false,
                shareTarget = false,
                bubble = false,
                shortcut = false,
            )
        }
        return Decision(
            markRead = true,
            reply = true,
            reaction = showReactionAction,
            shareTarget = true,
            bubble = true,
            shortcut = true,
        )
    }
}
