# services/ui/chat/ — Chat List & Conversation State

## Files
| File | Purpose |
|------|---------|
| `chats_service.dart` | Global chat list state — the source of truth for all `ChatState` objects |
| `conversation_view_controller.dart` | Per-chat controller for the active conversation screen |
| `logical_conversation_view.dart` | Fail-closed N-member read certificate, member provenance, excluded-candidate evidence, and deterministic projection helpers |
| `logical_conversation_route.dart` | Separate current-evidence write qualification; read membership never grants execution authority |

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
- Bind a service-generation handoff to its exact historical provider message;
  do not require that message to remain the predecessor's terminal message
  forever. Later predecessor activity fails closed until fresh current-member
  relationships, last-seen pointers, a unique writer, and a bounded natural
  response independently re-prove the current execution generation.
- Bind execution to the independently admitted external-participant count and
  public-safe set digest. Mutual equality among physical members is necessary
  but does not admit simultaneous participant co-drift.
- Advancement relationships must be successful, causal, cross-member edges to
  an exact authority-bearing natural message after the advancement cutoff.
- Never promote a predecessor or a new physical candidate from recent activity,
  title similarity, participant similarity, or service preference alone.

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
