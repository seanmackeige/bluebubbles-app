package com.mackeige.bluebubbles.services.notifications

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NotificationMutationPolicyTest {
    @Test
    fun terminalCandidateIsDisplayOnly() {
        val decision = NotificationMutationPolicy.decide(
            allowMutatingActions = false,
            showReactionAction = true,
        )

        assertFalse(decision.markRead)
        assertFalse(decision.reply)
        assertFalse(decision.reaction)
        assertFalse(decision.shareTarget)
        assertFalse(decision.bubble)
        assertFalse(decision.shortcut)
    }

    @Test
    fun ordinaryAndCertifiedNotificationsPreserveExistingActions() {
        val withReaction = NotificationMutationPolicy.decide(
            allowMutatingActions = true,
            showReactionAction = true,
        )
        assertTrue(withReaction.markRead)
        assertTrue(withReaction.reply)
        assertTrue(withReaction.reaction)
        assertTrue(withReaction.shareTarget)
        assertTrue(withReaction.bubble)
        assertTrue(withReaction.shortcut)

        val withoutReaction = NotificationMutationPolicy.decide(
            allowMutatingActions = true,
            showReactionAction = false,
        )
        assertTrue(withoutReaction.markRead)
        assertTrue(withoutReaction.reply)
        assertFalse(withoutReaction.reaction)
    }
}
