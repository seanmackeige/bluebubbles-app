package com.mackeige.bluebubbles.services.backend_ui_interop

import androidx.work.WorkInfo

/**
 * A notification action may update or clear human-visible state only after the
 * Dart worker reports success. Failed, cancelled, blocked, running, and pruned
 * work all preserve the notification for explicit reconciliation.
 */
object WorkerCompletionPolicy {
    const val CONTRACT = "NATIVE_WORKER_COMPLETION_POLICY_V1_SUCCESS_ONLY"

    @JvmStatic
    fun shouldCommit(state: WorkInfo.State?): Boolean = state == WorkInfo.State.SUCCEEDED
}
