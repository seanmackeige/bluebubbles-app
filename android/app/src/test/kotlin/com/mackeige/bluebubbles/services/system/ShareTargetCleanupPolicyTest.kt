package com.mackeige.bluebubbles.services.system

import org.junit.Assert.assertEquals
import org.junit.Test

class ShareTargetCleanupPolicyTest {
    @Test
    fun removesEveryDistinctLegacyMemberButPreservesLogicalIdentity() {
        assertEquals(
            listOf("physical-a", "physical-b", "physical-c"),
            ShareTargetCleanupPolicy.staleShortcutIds(
                listOf("physical-c", "physical-a", "physical-b", "physical-a", "logical-id", ""),
                listOf("logical-id")
            )
        )
    }

    @Test
    fun emptyOrFullyProtectedInputIsANoop() {
        assertEquals(emptyList<String>(), ShareTargetCleanupPolicy.staleShortcutIds(emptyList(), emptyList()))
        assertEquals(
            emptyList<String>(),
            ShareTargetCleanupPolicy.staleShortcutIds(listOf("logical-id"), listOf("logical-id"))
        )
    }
}
