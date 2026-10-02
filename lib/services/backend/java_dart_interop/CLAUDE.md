# services/backend/java_dart_interop/ — Dart ↔ Android Bridge

Three files that form the Dart side of the Android method channel bridge. The Kotlin side lives in `android/app/src/main/kotlin/com/bluebubbles/messaging/`.

For the full Android bridge overview, see `android/CLAUDE.md`.

## Files

### `method_channel_service.dart` — `MethodChannelService` / `MethodChannelSvc`

GetIt singleton. The primary bridge between Dart and Android. Uses `MethodChannel('com.bluebubbles.messaging')`.

**Calling Android from Dart:**
```dart
await MethodChannelSvc.invokeMethod("method-name", {"key": "value"});
```

Key methods invoked:
- `"push-notify"` — trigger a local notification
- `"delete-notification"` — clear a notification by ID
- `"start-foreground"` / `"stop-foreground"` — foreground service control
- `"get-server-url"` — read server URL from Android SharedPreferences

**Android calling Dart:** The service also registers a `MethodCallHandler` to receive calls from Kotlin (e.g. handling an incoming notification tap, background wake-up).

**Guards:** Initialization is skipped in headless/bubble/desktop modes. Always check `MethodChannelSvc.isAvailable` before calling on non-Android platforms.

---

### `intents_service.dart` — `IntentsService`

Handles Android intents arriving at the Flutter layer (share targets, notification deep links, app shortcuts).

Listens to `ReceiveIntent.receivedIntentStream` and routes by action:
- Share intent → pre-fill the chat composer with shared content
- Notification tap → open the correct conversation
- Custom deep link → navigate to the specified screen

---

### `background_isolate.dart`

Minimal setup for the Android background isolate (used when the app is killed but a Firebase push arrives). Stores a callback handle to `SharedPreferences` and defines the `@pragma('vm:entry-point')` entry point that initializes HTTP overrides and calls `StartupTasks.initBackgroundIsolate()`.

This is distinct from `GlobalIsolate` (see `lib/services/isolates/CLAUDE.md`) — it's the Android-specific background execution path, not the in-process Dart isolate used for DB operations.

## Notification Identity Contract

`create-incoming-message-notification` may include `conversation_key` and
`source_chat_guid`. Kotlin must fall back to `chat_guid` when either is absent so old
Dart payloads remain compatible. Background mark-read/reply work carries all three
identities back to Dart; routing still uses `chat_guid`, while logical actions re-resolve
and qualify the current presentation conversation before mutation.

## Notification Reply Operation Contract

Notification replies no longer use the legacy global recent-reply cache for
deduplication. notification_reply_operation.dart owns a privacy-safe durable
journal keyed by fingerprints of the exact conversation, source chat, source
message, and reply text. A reply stays retryable while reserved or
pre_execution_rejected; the outgoing queue persists execution_started only
after its final route/authority revalidation and immediately before provider
dispatch. Once that boundary is crossed, failures become outcome_ambiguous
and automatic replay is blocked. Only terminal or an already-terminal
duplicate lets the Android worker commit its notification callback.

This is a crash-durable local at-most-once barrier, not provider-distributed
exactly-once: SharedPreferences has no compare-and-swap across independent Dart
engines, and the messaging provider accepts no operation identity.

Terminal and ambiguous records compact to permanent operation-ID tombstones. They
are not age-evicted because an Android notification PendingIntent may remain live
indefinitely. The bounded active-record set may evict only
pre_execution_rejected entries, which prove zero provider execution and remain
reconstructible from the WorkManager payload.

A reply uses a deterministic privacy-safe temp message GUID. If final boundary
persistence fails after local preparation, the queue attempts DB, presentation,
and latest-message rollback before returning the retry signal. The stable GUID
ensures a retry reuses the same row even if local cleanup is partial.
