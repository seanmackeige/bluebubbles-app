package com.mackeige.bluebubbles.services.intents

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NotificationReactionActionPolicyTest {
    @Test
    fun currentPhysicalContractIsAdmitted() {
        assertTrue(
            NotificationReactionActionPolicy.mayDispatch(
                NotificationReactionActionPolicy.CURRENT_CONTRACT,
                NotificationReactionActionPolicy.CURRENT_INTENT_ACTION,
                "physical-guid",
                "physical-guid"
            )
        )
    }

    @Test
    fun staleOrLogicalActionsFailClosed() {
        assertFalse(
            NotificationReactionActionPolicy.mayDispatch(
                null,
                NotificationReactionActionPolicy.CURRENT_INTENT_ACTION,
                "physical-guid",
                "physical-guid"
            )
        )
        assertFalse(
            NotificationReactionActionPolicy.mayDispatch(
                NotificationReactionActionPolicy.CURRENT_CONTRACT,
                null,
                "physical-guid",
                "physical-guid"
            )
        )
        assertFalse(
            NotificationReactionActionPolicy.mayDispatch(
                NotificationReactionActionPolicy.CURRENT_CONTRACT,
                "legacy-or-forged-action",
                "physical-guid",
                "physical-guid"
            )
        )
        assertFalse(
            NotificationReactionActionPolicy.mayDispatch(
                NotificationReactionActionPolicy.CURRENT_CONTRACT,
                NotificationReactionActionPolicy.CURRENT_INTENT_ACTION,
                "lc.v1.certified.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "physical-guid"
            )
        )
        assertFalse(
            NotificationReactionActionPolicy.mayDispatch(
                NotificationReactionActionPolicy.CURRENT_CONTRACT,
                NotificationReactionActionPolicy.CURRENT_INTENT_ACTION,
                "different-physical-guid",
                "physical-guid"
            )
        )
        assertFalse(
            NotificationReactionActionPolicy.mayDispatch(
                NotificationReactionActionPolicy.CURRENT_CONTRACT,
                NotificationReactionActionPolicy.CURRENT_INTENT_ACTION,
                "",
                ""
            )
        )
    }
}
