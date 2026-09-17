# Logical Conversation View V2 — Generic Writable Execution Contract

Build 92 preserves the Build 90 presentation union and the Build 91 execution
boundary while replacing Build 91's unsupported raw-participant certificate
with `LOGICAL_CONVERSATION_OUTBOUND_ROUTE_V2_GENERIC_PROVENANCE`. The logical
conversation ID is never sent to the BlueBubbles server. A mutation reaches the
existing outbound pipeline only after current evidence qualifies the relevant
physical source.

## Read certification is not write authorization

An existing logical-definition certificate supplies only the current set of
physical source ROWID-to-GUID bindings admitted into the read projection. It
does not identify a writable member and contains no target-specific routing
answer. Similar-looking or future duplicate chats remain ordinary physical
conversations until their read equivalence is independently certified.

For a certified union, the runtime reads two stable snapshots of the current
iCloud account projection around fresh server, chat, participant, and complete
bounded message-history reads. Typed identities are normalized conservatively:
email case and `mailto:` syntax, or validated NANP/E.164 phone syntax. Opaque
values fail closed rather than being compared heuristically.

The generic new-message source is qualified only when all of these facts hold:

- backend and transport context are current;
- account snapshots are stable and the active sender is a vetted self alias;
- every source matches its certified current ROWID-to-GUID binding;
- every source has the same normalized external-participant set;
- every source's current addressed handle matches the active sender;
- exactly one source participant set excludes all vetted self aliases;
- that unique source has successful no-error outbound provenance; and
- its newest successful provenance is later than any alternative-source
  provenance.

The final timestamp check only rejects contradictory stale provenance. It can
never choose between multiple otherwise eligible sources. Input order, UI
order, highest ROWID, newest message alone, cached selection, and raw set
inclusion are not route selectors. Missing, duplicated, opaque, incomplete, or
contradictory evidence produces `ROUTE_NOT_PROVEN`.

Sean prod release assembly also verifies the packaged Dart AOT payload, not
only the source tree. Every packaged `libapp.so` must contain the V2 route
schema marker and must not contain the V1 marker. The prod native merge and
strip stages are forced to consume the current Flutter compiler output. This
closes the Build 92 failure in which current manifest/version metadata was
packaged around stale Build 91 Dart code.

UI qualification is never execution authority. Every queued logical mutation
forces a fresh evidence read before admission.

## Mutation routing

| Mutation | Execution target |
| --- | --- |
| New text or multipart | Unique current provenance-qualified writable physical source |
| Attachment without reply relationship | Same unique writable physical source |
| Reply | Exact certified physical source owning the target message GUID |
| Reaction/tapback | Exact certified physical source owning the target message GUID |
| Attachment in a reply action | Exact certified source owning the target message GUID; all attachments in that action retain the same route hint |
| Failed attachment retry | Certified physical source persisted by the original qualified attempt; missing or contradictory binding fails closed |
| Mark read | Only certified physical sources currently carrying represented unread state; zero or minimum required fanout |
| Scheduled send, edit, unsend, or unknown mutation | `ROUTE_NOT_PROVEN`; no mutation |

Target-message and read-state routes depend on certified source provenance, not
on new-message source selection. A reply or reaction therefore cannot be
silently rebound to the new-message source. Read state never fans out to a
source without represented unread state.

After admission, the existing `OutgoingMessageHandler` remains the sole send
engine. Text, multipart, reactions, and attachments continue through its normal
preparation, serial queue, HTTP/socket race, GUID replacement, retry, and error
handling. The logical layer creates neither a second transport nor an upload
path. Optimistic UI events retain their physical source relationships while the
presentation service projects them into the logical view.

## Exactly-once boundary

Each logical action receives its existing temporary message GUID before route
resolution. A bounded admission gate permits that identity once for an initial
action and once for an explicit retry. Rebuilds, rerenders, and duplicate
callbacks with the same identity cannot create another queue entry. Every
qualified outbound decision contains exactly one physical target. Read state
is the only operation allowed to contain multiple targets.

## Fail-closed behavior

Mutation controls remain unavailable while evidence is unchecked, checking, or
contradictory. The UI exposes `ROUTE_NOT_PROVEN` and a read-only route refresh.
No fallback chooses a physical chat. Direct execution on a certified source is
still blocked unless the mutation-specific resolver qualifies it.

## Rollback

Build 91 is the immediate Sean-lineage rollback APK, with Build 90 retained as
the read-only rollback artifact. The safe mechanism is an Android package
downgrade of `com.mackeige.bluebubbles` using a retained same-signer APK and
data preservation: verify exact device, package, artifact hash, and signer,
then use the normal replace/downgrade path and verify version, signer,
configuration, and session. Stop if Package Manager rejects it. Never
uninstall, clear data, or touch `com.bluebubbles.messaging`; static evidence is
sufficient until rollback is actually required.
