# android/ — Android Native (Kotlin)

Source: `app/src/main/kotlin/com/bluebubbles/messaging/`

## Key Modules
| Directory | Purpose |
|-----------|---------|
| `services/foreground/` | Foreground service to keep socket alive |
| `services/firebase/` | FCM push notifications and Firebase auth |
| `services/notifications/` | Notification channels, message/FaceTime builders |
| `services/intents/` | Intent receivers (deep links, auto-start) |
| `services/system/` | Calendar, contacts, browser, Chrome OS integrations |
| `services/network/` | Native HTTP service |
| `services/backend_ui_interop/` | DartWorkManager / DartWorker for background Dart |
| `services/filesystem/` | File path resolution |

## Dart ↔ Android Bridge
Flutter side: `lib/services/backend/java_dart_interop/`
- `method_channel_service.dart` — channel setup
- `intents_service.dart` — Android intent handling
- `background_isolate.dart` — background Dart execution

## Build Config
- Target SDK: 35 | NDK: 27.0 | Java/Kotlin compat: version 21
- Gradle with Kotlin plugin
- Sean prod builds force the Flutter native merge/strip stages to rerun and
  finish with `verifySeanProdReleaseAot`. The verifier rejects a packaged
  `libapp.so` that does not contain the current V5 write-authority-convergence
  logical-route and execution-generation schemas, the N-member read-
  certificate schema, and the write-authority convergence marker, or still
  contains the stale V1 route, V4 provider-fact route, or pair-certificate
  marker. `verifySeanStaleAotRegression` is the retained Build 92
  route negative control; `verifySeanPreNMemberAotRegression` is the retained
  Build 93 pair-certificate negative control.
- The daily-driver gate also requires the application snapshot, candidate
  quarantine, candidate-reconciliation context, deferred-notification,
  registry, multi-certificate ledger, authoritative GUID-bound V2 runtime
  certificate, certified-write-unavailable, settings, unread, search/media,
  and frozen new-group contracts in every packaged Dart `libapp.so`. The
  certificate-ledger/runtime-binding and unavailable-write markers ensure a
  certified logical conversation cannot silently fall back to an unbound
  physical writer. The gate also requires the worker-result, worker-completion,
  share-target-cleanup, physical-only notification-reaction, and bounded exact
  notification-event-history contracts in packaged `classes*.dex`.
- The Build 101 runtime fix advances immutably to Android `versionCode 20002107` after the
  rejected Build 102 through Build 106 candidates exposed remaining tile-read, contact-refresh,
  touch-triggered Flutter stretch-shader, timeline emoji-regexp, and timeline controller-rebind
  feedback paths. It is derived from base `20002000` plus Flutter build number `107`. Keep `pubspec.yaml` unchanged
  during qualification; the one authorized forward candidate build must pass
  `--build-number=107`. The release task rejects both a mismatched configured
  build number before assembly and mismatched AGP `output-metadata.json` after
  assembly. `verifySeanReleaseGateDefinitions` is the zero-package source and
  version-mapping preflight. `verifySeanReleaseGateRegression` independently
  removes each required AOT/native marker and exercises adjacent version codes
  to prove every gate fails closed.

## Logical Notification Contract

- New payloads group, deduplicate, and create conversation shortcuts by
  `conversation_key`; the exact `message_guid` remains the duplicate discriminator.
- `chat_guid` is retained for compatible navigation and `source_chat_guid` records
  physical provenance. Missing new fields must fall back to `chat_guid`.
- Mark-read/reply intents must carry all identities into background Dart work. Native
  code does not choose a new physical route for a logical conversation.
- The native Like/Love shortcut is physical-only. It is eligible only when the
  current contract token and versioned intent action are both present, the physical
  chat GUID is non-empty, and `conversation_key == chat_guid`. Certified logical
  conversations must use Dart's revision-bound reaction admission path, so their
  native notifications must not expose this shortcut.
- Missing, legacy, or mismatched reaction identity fails closed before notification
  mutation or network dispatch. Keep the reaction `PendingIntent` immutable and
  change its versioned intent action whenever this contract changes; extras are not
  part of Android `PendingIntent` identity and cannot distinguish a stale token.
