# Sean Edition daily-driver identity-leakage matrix

Audit base: accepted Build 99 source `bbbba0d2cd18de294b4f4ca223331eaa7241e221`.

This is the immutable pre-implementation Build 99 leakage baseline, not a
claim about the current candidate tree. It records why each conversion was
required and remains a negative-control checklist. Current implementation and
qualification evidence lives in the source contracts and focused tests named
in `LOGICAL_CONVERSATION_VALIDATION_CAMPAIGN.md`; the final handoff must report
their actual test/build/device state rather than reading the word "leak" below
as a current finding.

The convergence candidate remains release-pending until full regression,
independent Boss review, one immutable package, in-place S24 acceptance, and
passive soak pass. Frozen Build 100 / CREATE_CHAT_V2 is not part of this branch.

## Root finding

Build 99 has a correct N-member read projection and a separately qualified
physical write boundary, but it does not expose a first-class logical
conversation object. It suppresses certified source rows and exports the
certificate's presentation `Chat` as the UI surrogate. That physical GUID then
leaks into controller tags, list keys, notification groups, navigation,
search, settings, and queue presentation state.

The correction is additive:

```text
raw physical repository
  -> certified LogicalConversationId
  -> LogicalConversationSnapshot / ConversationAddress
  -> list, timeline container, draft, unread, notification, navigation,
     search and media presentation
  -> Build 99 atomic write admission
  -> exact PhysicalConversationRef only at the provider boundary
```

Physical chat and message identity remains mandatory provenance. A GUID is not
a leak merely because it exists; it is a leak when it is used as human
conversation identity or cached writer authority.

## Matrix

| Feature | Build 99 audit classification | Evidence / required correction |
|---|---|---|
| Raw `Chat` repository and ObjectBox relations | `PHYSICAL_BUT_CORRECT` | Raw Apple rows remain normalized source truth. |
| Public conversation list row/key | `PHYSICAL_IDENTITY_LEAK` | Projection returns one physical presentation member. Replace the public identity with `LogicalConversationId`. |
| Active conversation and controller/service tags | `PHYSICAL_IDENTITY_LEAK` | They are keyed by presentation GUID. Use a stable conversation key; ordinary chats retain behavior through a singleton logical identity. |
| Timeline physical member query | `PHYSICAL_BUT_CORRECT` | Querying certified source IDs and globally ordering exact messages is the correct provenance seam. |
| Message GUID and relationship GUID | `PROVENANCE_ONLY` | Exact message identities remain immutable; conflicting cross-source reuse fails closed. |
| Draft | `LOGICAL_NATIVE` | Build 96+ persists by logical ID and clears only after accepted queue custody. Preserve. |
| Final send route and receipt | `WRITE_PATH_REQUIRES_PHYSICAL_ROUTE` | Build 99 requalifies and binds one row/GUID immediately before dispatch. Preserve without shortcuts. |
| Send progress / pending operation UI | `PHYSICAL_IDENTITY_LEAK` | Admission rewrites the item to the writer chat, while UI observes the presentation member. Key UI state by logical operation/conversation. |
| Conversation-list latest message | `LOGICAL_NATIVE` with surrogate leak | Logical latest is derived across sources, but stored on a physical `ChatState`. Move the public answer to a snapshot. |
| Logical unread aggregate | `LOGICAL_NATIVE` | Boolean OR is correct. Add a monotonic per-source ledger and source-aware receipt state. |
| Tile / Mark All read action | `PHYSICAL_IDENTITY_LEAK` | Logical rows are excluded or guard-return. Route through the logical read plan. |
| In-app logical mark read | `WRITE_PATH_REQUIRES_PHYSICAL_ROUTE` | Exact currently unread sources are correct targets. Add partial-result accounting. |
| Notification identity | `PHYSICAL_IDENTITY_LEAK` | Android/desktop groups and payloads use presentation GUID/ID. Use logical key while retaining exact source event. |
| Notification reply | `PHYSICAL_IDENTITY_LEAK` at envelope; `WRITE_PATH_REQUIRES_PHYSICAL_ROUTE` at dispatch | Accept a logical address, then use normal Build 99 admission. |
| Notification mark read | `PHYSICAL_IDENTITY_LEAK` | Headless handler returns success without executing the logical plan. |
| Notification mute | `PHYSICAL_IDENTITY_LEAK` | Mute is evaluated on the incoming source before logical canonicalization. |
| Last-opened conversation | `PHYSICAL_IDENTITY_LEAK` | Persist a versioned `ConversationAddress`; support old GUID migration. |
| Deep links / notification taps / share targets | `PHYSICAL_IDENTITY_LEAK` | Compatibility may accept a source GUID, but navigation must resolve to logical ID before opening. |
| Direct-share shortcut key | `PHYSICAL_IDENTITY_LEAK` | Use stable logical conversation key; retain a physical presentation GUID only as a compatibility route payload. |
| Selected-conversation search | `PHYSICAL_IDENTITY_LEAK` | Local/server predicates search one physical GUID. Query all certified members. |
| Search result source message | `PROVENANCE_ONLY` | Exact source message and chat must remain on the result. |
| Search result navigation | `PHYSICAL_IDENTITY_LEAK` | It constructs a source-GUID-tagged service. Open the logical timeline at the exact message anchor. |
| Details media and links | `PHYSICAL_IDENTITY_LEAK` | Queries one physical chat. Query all certified members and retain owning message/attachment provenance. |
| Ctrl+I conversation details | `PHYSICAL_IDENTITY_LEAK` (release blocker) | Global shortcut bypasses the logical header guard and exposes rename/icon/participant/leave mutations on one member. Guard provider controls and provide logical read-only details. |
| Reply / reaction rendering | `PHYSICAL_BUT_CORRECT` | Merged messages and exact target GUIDs render correctly. |
| Reply / reaction execution | `WRITE_PATH_REQUIRES_PHYSICAL_ROUTE` | Exact target source and current capability must qualify separately; never infer writer from inbound activity. |
| Bookmarks / reply thread filtering | `PHYSICAL_IDENTITY_LEAK` | Bookmarks filter one physical GUID. Query the logical source set. |
| Incoming typing | `PHYSICAL_IDENTITY_LEAK` | Event updates a hidden physical controller. Resolve source to logical controller. |
| Outgoing typing | `WRITE_PATH_REQUIRES_PHYSICAL_ROUTE` | Currently disabled for certified logical conversations; keep blocked until authority-bound. |
| Pin/archive/mute/local preferences | `PHYSICAL_IDENTITY_LEAK` | Visible controls no-op or mutate the presentation member. Store human intent by logical ID. |
| Provider group settings | `WRITE_PATH_REQUIRES_PHYSICAL_ROUTE` | Name/photo/participants/leave remain provider mutations and must stay unavailable without a generation-scoped contract. |
| Custom groups | `PHYSICAL_IDENTITY_LEAK` | Membership is stored by physical GUID. Store a conversation identity with backward-compatible resolution. |
| Attachment scheduling priority | `PHYSICAL_IDENTITY_LEAK` | Source attachment GUID is compared to active presentation GUID. Compare logical conversation keys. |
| Candidate reconciliation | `LOGICAL_NATIVE` | Nomination, complete evidence, durable activation, and writer reevaluation remain separate. |
| Hydration cache | `PROVENANCE_ONLY` | Logical ID plus member binding/cursor/watermark is reconstructible acceleration, never authority. |
| Diagnostics | `PROVENANCE_ONLY` | Keep bounded hashes/IDs; do not expose raw topology in normal UI. |
| Legacy new-group endpoint | `UNKNOWN` / gated | Build 100 is frozen. This branch must explicitly block multi-recipient creation before legacy execution. |

## Accepted banked concepts

- immutable physical provenance;
- independent member proofs and complete-set certificate validation;
- nomination without blind enrollment;
- logical drafts with authority-revision revalidation;
- monotonic source unread ledger and partial read receipts;
- one logical notification identity with exact source event provenance;
- logical search/media results with exact source anchors;
- reconstructible incremental caches;
- diagnostics explain runtime policy but never override it.

## Superseded banked concepts

- The Build 95 reference `ServiceGeneration` model is not write authority.
  Build 99's generation definition `(service, account, external participant
  set)`, frontier/era logic, corroboration, and canonical-writer convergence
  remain authoritative.
- The old `9503124d4` full-client branch is a pattern library only. Its
  pair-specific force paths and weakened notification protection must not be
  merged.
- Python benchmark wall-clock and complexity labels are historical evidence,
  not Android runtime claims.

## Release order

1. canonical logical identity, registry/binding, snapshot and migration;
2. list/controller/navigation/notification/read commands;
3. search/media/reply-reaction presentation and bounded diagnostics;
4. failure/property/performance/full regression;
5. independent release-rejection review;
6. one immutable APK, in-place install, zero-send acceptance and passive soak.
