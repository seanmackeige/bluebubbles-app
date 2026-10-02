package com.mackeige.bluebubbles.services.backend_ui_interop

import androidx.work.WorkInfo
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WorkerCompletionPolicyTest {
    @Test
    fun `only success commits notification action state`() {
        assertTrue(WorkerCompletionPolicy.shouldCommit(WorkInfo.State.SUCCEEDED))
        assertFalse(WorkerCompletionPolicy.shouldCommit(WorkInfo.State.FAILED))
        assertFalse(WorkerCompletionPolicy.shouldCommit(WorkInfo.State.CANCELLED))
        assertFalse(WorkerCompletionPolicy.shouldCommit(WorkInfo.State.BLOCKED))
        assertFalse(WorkerCompletionPolicy.shouldCommit(WorkInfo.State.ENQUEUED))
        assertFalse(WorkerCompletionPolicy.shouldCommit(WorkInfo.State.RUNNING))
        assertFalse(WorkerCompletionPolicy.shouldCommit(null))
    }

    @Test
    fun `only literal dart true confirms worker success`() {
        assertTrue(DartWorkerResultPolicy.isConfirmedSuccess(true))
        assertFalse(DartWorkerResultPolicy.isConfirmedSuccess(false))
        assertFalse(DartWorkerResultPolicy.isConfirmedSuccess(null))
        assertFalse(DartWorkerResultPolicy.isConfirmedSuccess("true"))
        assertFalse(DartWorkerResultPolicy.isConfirmedSuccess(1))
        assertFalse(DartWorkerResultPolicy.isConfirmedSuccess(Unit))
    }
}
