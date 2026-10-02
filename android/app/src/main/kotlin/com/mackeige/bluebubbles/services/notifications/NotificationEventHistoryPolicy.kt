package com.mackeige.bluebubbles.services.notifications

object NotificationEventHistoryPolicy {
    const val CONTRACT = "LOGICAL_NOTIFICATION_EVENT_HISTORY_V1"
    const val EXTRA_KEY = "messageEventHistoryV1"
    const val MAX_EVENTS = 64

    enum class Admission {
        ADMIT,
        DUPLICATE,
        PROVENANCE_CONFLICT,
        INVALID_HISTORY
    }

    data class Decision(
        val admission: Admission,
        val encodedHistory: List<String>
    )

    private data class Event(val sourceChatGuid: String, val messageGuid: String)

    private fun encode(event: Event): String =
        "${event.sourceChatGuid.length}:${event.sourceChatGuid}${event.messageGuid}"

    private fun decode(value: String): Event? {
        val separator = value.indexOf(':')
        if (separator <= 0) return null
        val sourceLength = value.substring(0, separator).toIntOrNull() ?: return null
        val payload = value.substring(separator + 1)
        if (sourceLength <= 0 || sourceLength >= payload.length) return null
        val source = payload.substring(0, sourceLength)
        val message = payload.substring(sourceLength)
        if (source.isEmpty() || message.isEmpty()) return null
        return Event(source, message)
    }

    fun decide(
        encodedHistory: List<String>?,
        legacySourceChatGuid: String?,
        legacyMessageGuid: String?,
        sourceChatGuid: String,
        messageGuid: String
    ): Decision {
        if (sourceChatGuid.isEmpty() || messageGuid.isEmpty()) {
            return Decision(Admission.PROVENANCE_CONFLICT, encodedHistory.orEmpty())
        }

        val values = encodedHistory?.toList() ?: buildList {
            if (!legacySourceChatGuid.isNullOrEmpty() && !legacyMessageGuid.isNullOrEmpty()) {
                add(encode(Event(legacySourceChatGuid, legacyMessageGuid)))
            }
        }
        val events = values.map { decode(it) ?: return Decision(Admission.INVALID_HISTORY, values) }
        val proposed = Event(sourceChatGuid, messageGuid)
        if (events.any { it == proposed }) return Decision(Admission.DUPLICATE, values)
        if (events.any { it.messageGuid == messageGuid && it.sourceChatGuid != sourceChatGuid }) {
            return Decision(Admission.PROVENANCE_CONFLICT, values)
        }

        val next = (events + proposed).takeLast(MAX_EVENTS).map(::encode)
        return Decision(Admission.ADMIT, next)
    }
}
