package com.mackeige.bluebubbles.services.notifications

import org.junit.Assert.assertEquals
import org.junit.Test

class NotificationEventHistoryPolicyTest {
    @Test
    fun m1M2ReplayM1IsDuplicateAfterDurableRoundTrip() {
        val first = NotificationEventHistoryPolicy.decide(null, null, null, "source-a", "message-1")
        assertEquals(NotificationEventHistoryPolicy.Admission.ADMIT, first.admission)
        val second = NotificationEventHistoryPolicy.decide(
            first.encodedHistory,
            null,
            null,
            "source-b",
            "message-2"
        )
        assertEquals(NotificationEventHistoryPolicy.Admission.ADMIT, second.admission)

        val replayAfterProcessRestart = NotificationEventHistoryPolicy.decide(
            second.encodedHistory.toList(),
            null,
            null,
            "source-a",
            "message-1"
        )
        assertEquals(NotificationEventHistoryPolicy.Admission.DUPLICATE, replayAfterProcessRestart.admission)
        assertEquals(second.encodedHistory, replayAfterProcessRestart.encodedHistory)
    }

    @Test
    fun deferredReconciliationCrashUsesPostedLegacyEventAsDuplicate() {
        val replay = NotificationEventHistoryPolicy.decide(
            encodedHistory = null,
            legacySourceChatGuid = "source-a",
            legacyMessageGuid = "message-1",
            sourceChatGuid = "source-a",
            messageGuid = "message-1"
        )
        assertEquals(NotificationEventHistoryPolicy.Admission.DUPLICATE, replay.admission)
    }

    @Test
    fun sameMessageGuidWithDifferentSourceFailsClosed() {
        val first = NotificationEventHistoryPolicy.decide(null, null, null, "source-a", "message-1")
        val conflict = NotificationEventHistoryPolicy.decide(
            first.encodedHistory,
            null,
            null,
            "source-b",
            "message-1"
        )
        assertEquals(NotificationEventHistoryPolicy.Admission.PROVENANCE_CONFLICT, conflict.admission)
        assertEquals(first.encodedHistory, conflict.encodedHistory)
    }

    @Test
    fun malformedPersistedHistoryFailsClosed() {
        val decision = NotificationEventHistoryPolicy.decide(
            listOf("malformed"),
            null,
            null,
            "source-a",
            "message-1"
        )
        assertEquals(NotificationEventHistoryPolicy.Admission.INVALID_HISTORY, decision.admission)
    }

    @Test
    fun historyIsBoundedAndRetainsNewestExactEvents() {
        var history: List<String>? = null
        repeat(NotificationEventHistoryPolicy.MAX_EVENTS + 5) { index ->
            val decision = NotificationEventHistoryPolicy.decide(
                history,
                null,
                null,
                "source",
                "message-$index"
            )
            assertEquals(NotificationEventHistoryPolicy.Admission.ADMIT, decision.admission)
            history = decision.encodedHistory
        }
        assertEquals(NotificationEventHistoryPolicy.MAX_EVENTS, history!!.size)
        assertEquals(
            NotificationEventHistoryPolicy.Admission.DUPLICATE,
            NotificationEventHistoryPolicy.decide(
                history,
                null,
                null,
                "source",
                "message-${NotificationEventHistoryPolicy.MAX_EVENTS + 4}"
            ).admission
        )
    }
}
