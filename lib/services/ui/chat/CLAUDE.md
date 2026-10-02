# services/ui/chat/ — Chat List & Conversation State

## Files
| File | Purpose |
|------|---------|
| `chats_service.dart` | Global chat list state — the source of truth for all `ChatState` objects |
| `conversation_view_controller.dart` | Per-chat controller for the active conversation screen |
| `logical_conversation_registry.dart` | Immutable multi-conversation application registry with disjoint certified members, deterministic reverse lookup, projection, and canonical snapshot construction |
| `logical_conversation_registry_binding.dart` | Pure fail-closed adapter from certified read certificates plus current runtime bindings into the application registry |
| `logical_conversation_application_snapshot.dart` | Central privacy-safe application projection over certified/runtime membership, latest-message provenance, unread, draft, settings, notifications, indexes, and health |
| `logical_conversation_view.dart` | Multi-authority read policy, explicit banked Build 99 writer alias, runtime binding, member provenance, and deterministic projection helpers |
| `logical_conversation_certificate_ledger.dart` | Versioned privacy-safe certificate authority ledger keyed by opaque `LogicalConversationId`; rejects runtime coordinates and protects whole-ledger revision integrity |
| `logical_conversation_certificate_binding.dart` | Read-only ObjectBox adapter that binds every ledger authority's stable GUID fingerprints to current chat ROWIDs after database initialization |
| `logical_certificate_advancement_transaction.dart` | Process-wide exact-target queue covering fresh durable load, revision check, merge, persistence, and runtime activation |
| `logical_candidate_reconciliation_context.dart` | Privacy-safe per-logical-ID service/external-participant contexts used only to nominate and protect provider candidates |
| `logical_candidate_quarantine.dart` | Durable candidate evidence state machine and shared phase-aware list/search/share presentation admission policy |
| `logical_mutation_protection.dart` | Pure precedence model for certified, quarantined, pre-nomination, and corrupt-authority mutation protection |
| `logical_conversation_health.dart` | Pure public-safe health projection over certified snapshots and closed runtime evidence states |
| `logical_conversation_route.dart` | Separate current-evidence write qualification; read membership never grants execution authority |
| `logical_execution_authority.dart` | Write-authority convergence: execution generations, frontier/era, corroboration, writer selection, bounded diagnostics |

---

## ChatsService (`chats_service.dart`)

GetIt singleton. Accessed via `ChatsSvc`.

**What it owns:**
- `chatStates` — `Map<String, ChatState>` keyed by chat GUID; every `ChatState` lives here
- `_sortedChats` — ordered list of chats for the conversation list UI
- `chatListVersion` — `RxInt` that increments when sort order changes; conversation list `Obx()` watches this

**Key methods:**
- `updateChat(Chat, {override})` — merges a chat update into its `ChatState` and repositions if needed
- `getChatState(String guid)` → `ChatState?` — the standard way to get reactive state for a chat
- `setAllInactive()` — marks all chats as not active (called when navigating away)
- `getActiveChat()` → `ChatState?` — the currently open chat

**Loading:** Chats are loaded in batches of 100 (`loadChats()`). After the initial load, incremental updates come through `updateChat()`.

**Rules:**
- Certificate authority is a single revisioned V2 ledger. Validate every root
  and monotonic certificate independently, reject cross-entry provider or
  runtime-row collisions, and never recover a corrupt V2 ledger from the V1
  singleton. V1 is only an idempotent first-run migration source.
- If an authoritative V2 ledger is present but corrupt, its protection index is
  unknowable. Treat every runtime chat as mutation-protected until authority is
  repaired; never infer ordinary-chat safety from the now-empty registry.
- `activeCertificate` is intentionally the banked Build 99 writer alias.
  Read-side protection, projection, membership, and source backfill use the
  union of every fully bound ledger entry; incomplete entries retain identity
  in the ledger but grant no runtime mutation authority.
- Never write to a `ChatState` directly from UI — always call a `ChatsService` method
- Never sort the chat list manually — call `updateChat()` and let the service reposition
- Registry membership must stay explicit and globally disjoint; a shared
  physical reference, provider fingerprint, or runtime ROWID invalidates the
  registry instead of merging human conversations.
- Build 99 writer and draft-execution authority remains gated to the banked
  Comcast logical ID. Durable unread/read ledgers are per logical ID; other
  certified entries remain read-capable but fail closed for outbound mutation.
- Candidate reconciliation is registry-wide. Derive each context only from the
  exact normalized external participants and service of its certified members
  after vetted provider-self aliases are removed. Context equality nominates
  and mutation-protects; it never certifies, merges, or changes writer state.
- A candidate that uniquely matches one context may advance only that exact
  ledger entry after independent provider-backed reconciliation and immediate
  account/scope/revision revalidation. Ambiguous matches fail closed and remain
  physically visible/read-only; title and recency are never enrollment facts.
- Every certificate advancement must use the process-wide transaction queue.
  Fresh durable state, exact persisted target revision, merge, one-value V2
  write, main runtime activation, and isolate activation are one serialized
  critical section. Concurrent entries must compose; stale same-entry work
  must perform no second write.
- A certified read-only conversation must never read, display, invalidate, or
  schedule a recheck of the global Comcast writer status or ambiguity ledger.
  Use `hasBuild99WriterCapability()` before entering any writer surface; show
  the bounded read-only/write-unavailable state for every other logical ID.
- Read-only hydration/cache identity and draft observation use certificate and
  source-local evidence only. They must not inherit the Comcast authority
  revision merely because the process has observed the banked writer.
- To read the chat list in a widget: `Obx(() => ChatsSvc.sortedChats)` gated on `chatListVersion`
- Add a physical chat to a logical projection only with its own complete
  `LogicalConversationMemberProof`; title similarity and transitive equivalence
  are not admission evidence.
- Keep read membership and outbound routing independent. An N-member read
  certificate has no writable target; current route evidence must qualify one.
- Never promote a predecessor or a new physical candidate from recent activity,
  title similarity, participant similarity, or service preference alone.
- Apply `logicalCandidatePresentationAdmission` consistently: nominated,
  reconciling, and certified-but-not-active physical candidates are suppressed;
  active-certificate members are canonical; rejected and expired-visible
  candidates are ordinary read-only presentation. Active candidate physical
  shortcuts must be removed, while terminal-visible candidates may be
  recreated ordinarily.
- Bind execution to the independently admitted external-participant count and
  public-safe set digest. Mutual equality among physical members is necessary
  but does not admit simultaneous participant co-drift.

### Write-authority doctrine (`logical_execution_authority.dart`)
1. A physical chat is not an execution generation. A generation is
   (service, account, external participant set); physical chats are its
   representations.
2. A representation with no vetted self alias is a `CANONICAL_ROUTE`; one that
   adds exactly one vetted self alias is a `SELF_ALIAS_VARIANT` of the same
   generation. A variant is read-equivalent and may be a reply source; it is
   never a writer.
3. A reply/reaction source is not a writer. Relationship mutations execute in
   the target's own chat and require the target to be in the current
   generation.
4. The current generation is the generation of the latest provider-accepted
   outbound (from-me, normal, error 0) across every certified member. Its era
   is the maximal chronological suffix of outbounds on that generation;
   outbounds sharing the boundary timestamp have no provable order and are
   excluded from it.
5. Sean's own successful outbound is the strongest writer evidence; a failed
   attempt is not evidence of anything.
6. An era arms only with corroboration of at least one of its outbounds:
   certified terminal facts, a structured response from another participant,
   or a bounded natural response in the same generation. Sean continuing his
   own thread is not corroboration.
7. Inbound messages, reactions (structured or literal quoted text), read
   pointers, hybrid state and group photo/identifier metadata never move the
   frontier. They can only add corroboration: they may arm the frontier
   generation's writer, but never remove, re-select or create a writer on any
   other row. Group identity is lineage metadata, not authority.
8. A successful outbound in a different generation invalidates the old writer
   immediately; the new generation writes only after its own corroboration.
9. Writer = the unique canonical route of the current generation, proven by a
   corroborated outbound of its own in the current era. Between several
   canonical routes, recency of era outbounds discriminates only when the most
   recent sender's corroboration is local to its own row. No discriminator or
   an exact timestamp tie at the frontier or between canonical routes is
   `SEND_BLOCKED_TRUE_MULTI_WRITER_AMBIGUITY`; no canonical
   route or no corroboration is `SEND_BLOCKED_NO_CURRENT_WRITER`.
10. Serializer omission is `unavailable`, never `false`; any present provider
    contradiction, unadmitted same-set candidate, or unstable snapshot is
    `SEND_BLOCKED_INVARIANT`.
11. Authority revision digests only execution invariants plus the derived
    decision. Identical evidence yields a byte-identical revision, and an
    in-process re-observation of identical authority restores its epoch; a
    new process still forces one draft re-arm.
12. Only Sean's own execution events invalidate admission state; other
    participants' events only drop cached evidence. Presentation keeps the
    last evaluated state while a debounced passive re-check re-derives it.
13. Authority is a pure function of freshly collected provider evidence; no
    cache or persisted state is ever its source of truth.
14. Decision logic never references ROWIDs, GUIDs or other coordinates of a
    particular conversation; certificates carry membership data only.
15. The composer shows nothing when send is ready; a block states its specific
    reason, with bounded diagnostics behind the info button.

---

## ConversationViewController (`conversation_view_controller.dart`)

GetX controller, one instance per open application conversation. Access it via
`cvc(chat)`; its tag is `ChatsSvc.conversationKeyFor(chat)`, which is the stable
logical key for certified conversations and the existing physical GUID for an
ordinary chat. Existing-controller lookup is read-only. Only the route/peek
owner may request `cvc(chat, bindPresentation: true)`; passive message, action,
and focus lookups must never rebind presentation during a widget build.

**What it owns:**
- `pickedAttachments` — files staged for sending
- `replyToMessage` — the message being replied to
- `editing` mode flag
- `AutoScrollController` for the message list scroll position
- Media caches: sticker widgets, video players, audio players (keyed by attachment GUID)

**Key properties:**
- `isAlive` — `RxBool`; false when the view is popped. Check this before posting to the controller.
- `sendFunc` — callback registered by `SendAnimation`; call `controller.send(...)` to trigger it

**Lifecycle:** Created when a conversation opens, closed when it pops. A conversation can remain "alive" in the background when in tablet mode.

**Rule:** Never hold a direct reference to `ConversationViewController` across navigations — always re-fetch via `cvc(chat)`.
