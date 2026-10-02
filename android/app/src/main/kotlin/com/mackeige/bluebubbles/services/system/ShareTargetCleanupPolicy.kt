package com.mackeige.bluebubbles.services.system

/** Pure policy for removing legacy physical shortcuts without touching the
 * canonical logical shortcut (or any other explicitly protected identity). */
object ShareTargetCleanupPolicy {
    const val CONTRACT = "NATIVE_SHARE_TARGET_CLEANUP_POLICY_V1_PROTECTED_IDENTITIES"

    fun staleShortcutIds(candidates: Iterable<String>, protectedIds: Iterable<String>): List<String> {
        val protected = protectedIds.filter { it.isNotBlank() }.toSet()
        return candidates
            .filter { it.isNotBlank() && it !in protected }
            .distinct()
            .sorted()
    }
}
