# Logical Conversation View V2 — N-Member Read and Generic Execution Contract

Build 94 evolves the accepted Build 93 pair projection into
`LOGICAL_CONVERSATION_READ_CERTIFICATE_V2_N_MEMBER`. Each physical presentation
member carries its own GUID binding, evidence classes, pairwise differential,
direct structured relationship evidence, admission receipt, and operator
explanation. Removing one proof removes only that member. Input order cannot
change membership, and neither a matching title nor transitive equivalence can
enroll a candidate.

The certified Comcast Node Updates read set is 2027, 2155, and 2156. Physical
candidate 1674 is retained separately as a historical/inert prior-participant-
set lineage and is not enrolled. The presentation layer exposes one chat and
one chronology while preserving physical chat, message, attachment, reaction,
reply, delivery, read, and group-metadata provenance. Equal content remains
distinct unless exact message identity is proven.

The independent write boundary remains
`LOGICAL_CONVERSATION_OUTBOUND_ROUTE_V2_GENERIC_PROVENANCE`. The logical
conversation ID is never sent to the BlueBubbles server. A mutation reaches the
existing outbound pipeline only after current evidence qualifies the relevant
physical source.

## Read certification is not write authorization

An N-member read certificate supplies only the physical source ROWID-to-GUID
bindings admitted into the projection. It does not identify a writable member
and contains no route-generation or target-specific routing answer. Similar-
looking or future duplicate chats remain ordinary physical conversations until
their read equivalence is independently certified.

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

For the expanded 2027/2155/2156 set, both 2027 and 2156 remain write-eligible
under current evidence. Inbound recency, newest chat/message, ROWID, UI order,
and successful historical sends cannot establish a current execution epoch.
The compose route therefore returns
`ROUTE_NOT_PROVEN_EXPANDED_SET_AMBIGUOUS`. This does not block the proven read
projection and does not hard-code either physical identity as the writer.

Sean prod release assembly also verifies the packaged Dart AOT payload, not
only the source tree. Every packaged `libapp.so` must contain the V2 route and
N-member read-certificate markers and must contain neither the V1 route nor
prior pair-certificate marker. The prod native merge and strip stages are
forced to consume the current Flutter compiler output. Build 92 is retained as
the stale-route negative control and Build 93 as the pair-certificate negative
control.

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

Build 93 is the immediate same-lineage rollback APK, with Build 90 retained as
the accepted read-only pair rollback artifact. The safe mechanism is an Android package
downgrade of `com.mackeige.bluebubbles` using a retained same-signer APK and
data preservation: verify exact device, package, artifact hash, and signer,
then use the normal replace/downgrade path and verify version, signer,
configuration, and session. Stop if Package Manager rejects it. Never
uninstall, clear data, or touch `com.bluebubbles.messaging`; static evidence is
sufficient until rollback is actually required.
