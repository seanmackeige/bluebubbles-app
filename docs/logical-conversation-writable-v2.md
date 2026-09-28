# Logical Conversation V3 — Evidence-Driven Read and Execution Generations

Build 97 retains `LOGICAL_CONVERSATION_READ_CERTIFICATE_V2_N_MEMBER` and
replaces the fixed Comcast execution cutover with
`LOGICAL_EXECUTION_GENERATION_CERTIFICATE_V3_EVIDENCE_GRAPH`. Read membership
and write authority remain separate facts.

The banked Comcast Node Updates read root contains physical chats 2027, 2155,
and 2156. Each member carries its own provider GUID binding, exact normalized
external-participant proof, pairwise comparison, direct structured relationship
evidence, passive natural history, and admission receipt. Candidate 1674
remains a historical related identity with a different participant set and is
not enrolled.

The presentation layer exposes one conversation list row and one canonical
timeline while preserving physical chat, message, attachment, reaction, reply,
delivery, read, and group-metadata provenance. Equal content is never a merge
key; only exact message identity may collapse an exact duplicate.

## Evidence-driven read advancement

The complete server chat universe is read twice around stable account, server,
chat, participant, and bounded full-history snapshots. A new physical identity
is nominated only when its normalized external participant set exactly matches
the accepted set. A related group identity with a different participant set is
classified as historical/different-set and does not disable a proven writer.

A nominated identity enters the active read certificate only when it has:

- stable provider ROWID/GUID parity across complete snapshots;
- exact external-participant-set parity with every certified member;
- a direct exact reply or reaction relationship to an original certified
  member, never merely another new candidate;
- structured group-ID or group-photo continuity;
- passive natural production history; and
- a content-addressed evidence receipt.

Admission is compare-and-swap against the observed certificate revision. The
content-addressed certificate is durably stored before it atomically changes
list/timeline projection and mutation guards, then it is hydrated in every
isolate, invalidates cached authority, and forces a fresh execution read. Every
transport operation reloads the durable certificate before validation. A
restart therefore preserves later admissions without turning them into
ordinary chats; corrupt or unavailable state fails closed at the logical send
boundary. Matching title, content similarity, candidate order,
transitive-only evidence, and highest/newest ROWID cannot admit a candidate.

## Evidence-driven execution succession

Every certified physical GUID is a generation-graph node. Exact replies and
reactions supply directed successor-to-predecessor edges when chronology and
group identity agree. Service/account is evidence attached to a node, not its
identity: Apple may return to the same iMessage account after an intervening
SMS generation without creating a false cycle.

Two physical peers can form one execution generation only when all of these
hold:

- service and account match;
- exactly one peer contains a vetted self alias;
- a direct structured relationship joins them;
- the no-self peer has an account-bound terminal successful outbound; and
- the self-variant peer has a bounded natural response after that outbound.

The current generation is the unique graph head and must reach every certified
predecessor generation. Every current member must carry natural activity and
an exact last-seen pointer newer than all predecessor activity. The current
generation must contain exactly one no-self physical writer. Its terminal
successful outbound must be present in the same complete provider snapshot,
match the current account, postdate predecessor advancement, and have a bounded
natural response.

Zero heads, multiple heads, incomplete succession, participant drift, account
drift, missing terminal outcome, stale last-seen evidence, or zero/two writers
fail closed with a bounded underlying reason. Candidate order, UI order,
display title, highest ROWID, newest message alone, and historical success are
never writer selectors.

For the 2026-09-28 observed topology, this graph identifies the current SMS
generation and its one no-self writer at row 2156. That conclusion comes from
the exact participant set, current service/account, direct relationships across
2027/2155/2156, the natural 06:59 terminal outbound, its later natural reply,
and the self-alias differential. It is not a hard-coded row selection.

## Transport and execution boundary

Route authority is independent of transport readiness. Authoritative current
unavailability blocks; an SMS relay whose reachability is not continuously
observable remains bounded unknown and is evaluated by Apple's normal send
semantics. Unknown reachability never revives or retries an old ambiguous
operation.

UI qualification is not execution authority. Every queued logical mutation
forces a fresh provider evidence read, binds an immutable authority revision,
and must pass the durable atomic admission ledger before the existing
`OutgoingMessageHandler` may dispatch it. One logical action can execute at
most once. Draft identity remains logical and survives certificate or authority
advancement without acquiring a physical target until admission.

Replies, reactions, and reply attachments retain the exact physical source and
target message GUID. Mark-read touches only represented unread certified
sources. Unsupported mutations remain blocked. No fallback route exists.

## Release attestation and rollback

Sean release assembly verifies the packaged Dart AOT payload. Every packaged
`libapp.so` must contain the V3 evidence-graph marker, the evidence-
reconciliation marker, the durable runtime-certificate marker, the N-member
read marker, logical draft/admission markers, and incremental projection
marker; stale V1 route and pair-certificate markers are forbidden. Retained
Build 92 and Build 93 APKs remain negative AOT controls.

Build 96 is the immediate same-lineage rollback candidate once its exact
artifact, hash, signer, and device compatibility are revalidated. Any install
or rollback must use an in-place same-signer package replacement that preserves
data. Never uninstall, clear data, or mutate `com.bluebubbles.messaging`.
