# Logical Conversation View V2 — Writable Execution Contract

Build 91 preserves the Build 90 presentation union and adds a separate,
fail-closed execution layer. The logical conversation ID is never sent to the
BlueBubbles server. A mutation reaches the existing outbound pipeline only
after `LOGICAL_CONVERSATION_OUTBOUND_ROUTE_V1` resolves exactly one certified
physical chat.

## Certified scope

The only writable logical definition is the accepted Comcast Node Updates
pair, source ROWIDs 2155 and 2156. The certificate binds both current chat
GUIDs, chat identifiers, participant-set digests, the exact backend identity,
the current account context, the current routing handle, and retained
successful-natural-outbound anchors. The canonical new-message route is source
2156 because it is the current external-participant route with the accepted
outbound provenance; source 2155 is the historical self-alias-bearing variant.
Selection is therefore independent of source ordering, UI ordering, highest
ROWID, latest message, or cached UI state.

The runtime re-reads the server metadata, both chats with participants, and
their message identities before enabling compose. Any missing or contradictory
fact produces `ROUTE_NOT_PROVEN`. Similar-looking or future duplicate pairs do
not inherit this certificate. UI qualification is never execution authority:
every queued logical mutation forces a fresh evidence read before admission.

## Mutation routing

| Mutation | Execution target |
| --- | --- |
| New text or multipart | Certified canonical physical chat |
| Attachment without reply relationship | Certified canonical physical chat |
| Reply | Exact physical chat owning the target message GUID |
| Reaction/tapback | Exact physical chat owning the target message GUID |
| Attachment in a reply action | Exact physical chat owning the target message GUID; all attachments in that UI action retain the same route hint |
| Failed attachment retry | The certified physical source persisted by the original qualified attempt; a missing or contradictory persisted binding fails closed |
| Mark read | Only certified physical source chats currently carrying represented unread state; zero, one, or two read mutations |
| Scheduled send, edit, unsend, or unknown mutation | `ROUTE_NOT_PROVEN` / existing logical guard; no mutation |

After admission, the existing `OutgoingMessageHandler` remains the sole send
engine. Text, multipart, reactions, and attachments continue through its normal
preparation, serial queue, HTTP/socket race, GUID replacement, retry, and error
handling. The logical layer does not create a second transport or upload path.
Optimistic UI events are projected into the presentation service while their
database relationship remains bound to the selected physical chat.

## Exactly-once boundary

Each logical action receives its existing temporary message GUID before route
resolution. A bounded admission gate permits that identity once for an initial
action and once for an explicit retry. Rebuilds, rerenders, and duplicate
callbacks with the same identity cannot create an additional queue entry.
Every qualified outbound decision contains exactly one physical target. Read
state is the sole operation allowed to contain multiple physical targets.

## Fail-closed behavior

Mutation controls remain unavailable while evidence is unchecked, checking,
or contradictory. The UI exposes `ROUTE_NOT_PROVEN` and a read-only retry of the
qualification query. No fallback chooses a physical chat. Direct execution on
an approved source remains blocked unless it passes the same resolver.

## Rollback

Build 90 remains the immediate Sean-lineage rollback APK. The safe mechanism is
an Android package downgrade of `com.mackeige.bluebubbles` using the retained,
same-signer Build 90 APK with data preservation enabled: after verifying the
connected device identity, installed package, retained APK hash, and signer,
run `adb -s <exact-device> install -r -d <retained-build-90.apk>`, then verify
version, signer, configuration, and session. Stop without uninstalling if
Package Manager rejects the downgrade. Do not uninstall, clear data, or touch
`com.bluebubbles.messaging`. A rollback is not exercised merely for proof;
signer/package/version/archive evidence is sufficient until a real rollback is
required.
