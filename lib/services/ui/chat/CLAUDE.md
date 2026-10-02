# services/ui/chat/ — Chat List & Conversation State

## Files
| File | Purpose |
|------|---------|
| `chats_service.dart` | Global chat list state — the source of truth for all `ChatState` objects |
| `conversation_view_controller.dart` | Per-chat controller for the active conversation screen |
| `logical_conversation_view.dart` | Fail-closed N-member read certificate, member provenance, excluded-candidate evidence, and deterministic projection helpers |
| `logical_conversation_route.dart` | Separate current-evidence write qualification; read membership never grants execution authority |
| `logical_execution_authority.dart` | Write-authority convergence: execution generations, frontier/era, corroboration, writer selection, bounded diagnostics |
| `new_group_conversation.dart` | Offline fail-closed new-group intent, capability, exact-match, admission, ambiguity, and Apple-observation policy |
| `new_group_provider_contract.dart` | Narrow provider adapter, durable full state machine, conditional authority, strong result reconciliation, and Build 100 UI gate |
| `new_group_create_chat_v2.dart` | Explicit CREATE_CHAT_V2 wire contract, capability negotiation, exact bound response checks, and durable provider at-most-once journal model |
| `new_group_operation_store.dart` | Crash-durable preference journal and explicit non-executing production boundary |

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
- Never write to a `ChatState` directly from UI — always call a `ChatsService` method
- Never sort the chat list manually — call `updateChat()` and let the service reposition
- To read the chat list in a widget: `Obx(() => ChatsSvc.sortedChats)` gated on `chatListVersion`
- Add a physical chat to a logical projection only with its own complete
  `LogicalConversationMemberProof`; title similarity and transitive equivalence
  are not admission evidence.
- Keep read membership and outbound routing independent. An N-member read
  certificate has no writable target; current route evidence must qualify one.
- Never promote a predecessor or a new physical candidate from recent activity,
  title similarity, participant similarity, or service preference alone.
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

### New-group creation doctrine (`new_group_conversation.dart`)
1. A new logical conversation has recipients, service, account/sender, draft,
   attachments, and an operation identity, but no physical chat GUID or ROWID.
2. Recipient normalization belongs to authoritative resolution. Admission never
   repairs, drops, adds, or silently changes a normalized handle or service.
3. An exact existing recipient/service/account match requires explicit human
   selection; current, historical, and multiple matches are never auto-reused.
4. A macOS version is not a capability. Private API, helper action, account and
   sender binding, durable operation reservation, and Apple observation are
   proven independently and must all be current before admission. Server and
   helper must negotiate the complete `CREATE_CHAT_V2` token set; omission or
   version skew fails closed.
5. Admission and execution-started records must be durably persisted before a
   transport call. Any interruption after execution starts becomes
   `outcomeAmbiguous` and must not be retried automatically.
6. Success requires one terminal first message and an Apple-created chat whose
   exact recipients, service, account, sender, and content match the intent.
7. This policy must remain transport-disconnected until a native provider
   implements and runtime-proves the complete `CREATE_CHAT_V2` account, sender,
   service, operation-identity, and result-observation contract.
8. Build 100 may inspect and explain current capability, but unresolved groups
   never invoke `/chat/new`; the production execution boundary remains false.
9. Existing exact-set groups activate only after explicit physical-chat
   selection and remain existing-chat sends, never new-group creation.

---

## ConversationViewController (`conversation_view_controller.dart`)

GetX controller, one instance per open chat. Accessed via `cvc(chat)` helper or `Get.find<ConversationViewController>(tag: chat.guid)`.

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
