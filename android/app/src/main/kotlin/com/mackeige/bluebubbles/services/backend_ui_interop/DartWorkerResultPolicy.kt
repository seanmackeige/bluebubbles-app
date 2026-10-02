package com.mackeige.bluebubbles.services.backend_ui_interop

/**
 * Converts the value returned by the Dart method-channel handler into a native
 * worker decision. Dart uses the literal Boolean values as its completion
 * contract: true is terminal success and false requests a retry. Null and
 * malformed values fail closed through the same retry-or-fail path.
 */
object DartWorkerResultPolicy {
    const val CONTRACT = "NATIVE_DART_WORKER_RESULT_POLICY_V1_LITERAL_TRUE_ONLY"

    @JvmStatic
    fun isConfirmedSuccess(result: Any?): Boolean = result == true
}
