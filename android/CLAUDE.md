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
- Build 108 remains the immutable accepted ANR/UI baseline (`20002108`). Its
  logical draft admission behavior is rejected for the proven raw-certificate
  versus application-key namespace defect after legitimate consumption.
- The isolated draft correction uses the next verified unused Sean version,
  `20002109` (Flutter `--build-number=109`; base `20002000`). Keep `pubspec.yaml`
  unchanged. See `docs/qualification/build108-logical-draft/INCIDENT.txt` for
  source-linked reproduction, original-runtime limits, and acceptance gates.
- The release gate requires bounded admission diagnostics in every packaged
  Dart `libapp.so`, in addition to all existing authority/native contracts.
  It rejects mismatched build input and output metadata. Run
  `verifySeanReleaseGateDefinitions` and `verifySeanReleaseGateRegression`
  before packaging; negative controls include immutable 108 and adjacent 110.
  Build 109 is a candidate until real S24 draft-preserving installation and
  zero-send acceptance complete. Never overwrite the archived Build 108 APK.

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

## Build 109 packaging rejection and proposed Build 110

Build 109 is immutable and rejected: the first clean-worktree `--no-pub` build
omitted ignored `GeneratedPluginRegistrant.java`. Its56 plugin classes existed,
but the registration entrypoint did not. S24 startup failed before file-system
initialization. No message was sent. Do not reuse version20002109 or its APK.

Regenerate tooling with `flutter pub get --offline --enforce-lockfile` before
building. The preassembly gate now requires the exact accepted generated source
for the locked56-plugin set. Packaged verification parses DEX class definitions
and requires the registrant and all56 implementation classes; string references
are insufficient. Update that pinned source hash only with reviewed dependency
or toolchain changes. `BLUEBUBBLES_PYTHON` can select the standard-library Python
interpreter used by the package gate.

Sean explicitly authorized one additional immutable recovery candidate,
version20002110/build110, after the Build109 packaging rejection. Build110
remains pending real S24 zero-send acceptance; no automatic message is allowed.


### 2026-10-05 Build110 recovery device receipt
Build110/20002110 from66d12ad68 is installed in place on the attested S24 and
starts successfully. Established signer; package hash and UID/first-install
continuity verified. No uninstall, data clear or assistant Send tap.
Zero-send UI acceptance passed with one logical Comcast row and no new bounded
ANR/crash/OOM. Current empty composer was preserved after Sean confirmed his
intentional earlier clear/change. Retained draft authority is STALE and needs
revalidation; typing alone retains it. Live admission remains untested and a
first natural tap may pause to rearm. Stop/read back before any retry.
Do not classify full end-to-end resolution or first-tap send readiness as proven.
See docs/qualification/build108-logical-draft/device-build110/HANDOFF.txt and
BUILD110-STALE-EMPTY-REVIEW.txt. Build109 remains immutable/rejected. No additional
APK authorized by the one-build110 recovery exception. Apple validation/TLS patch
and all production Mac/routing protections remain separate and unchanged.

### Build111 admission readiness correction
Current mission authorizes one further immutable candidate after complete proof.
Next verified unused version20002111/build111. Build110 starts but is not accepted
for first-tap admission: its epoch-only pause violates the unchanged-intent contract.
Release gates now require the shared-policy local preflight and expected epoch
alignment markers as well as every prior AOT/native/plugin constraint.
Build108/109/110 archive bytes remain immutable. No synthetic send is permitted.


### 2026-10-05 Build111 installed; live admission readiness BLOCKED
Build111/20002111 from e031e98e39 is installed in place on the same attested S24.
Exact APK hash, original package UID and first-install continuity verified. No
uninstall, clear-data, assistant typing or Send tap. A new nonempty human Comcast
 draft appeared on110 during packaging and survived reopen,111 installation and
reopen with identical fingerprint. The original1029 draft had earlier been
cleared/changed by Sean and was not recreated.
538 full regression and71 current-source independent adversarial cases PASS.
Historical95 separately labeled. Startup/UI and bounded no-ANR/crash/OOM PASS.
Live read-only probe BLOCKED: coherent nonempty draft generation0/contentRevision11
has null observed certificate/authority/epoch, while current scoped proof exists.
This is missing proof, not evidence of actual certificate drift or an epoch-only
exception. Nine pure policy cases PASS cannot establish live send readiness.
Runtime diagnostic truncates at1023UTF8 bytes; only complete prefix fields are
banked and its suffix is unobserved. Do not invent complete JSON/no-write fields.
No non-sending review/rebind control exists in111. Do not ask Send, silently rebind,
clear/retype, or auto-retry. The one-candidate limit is consumed. A separate extra
candidate requires new authorization; first prepare/review an explicit non-sending
Review draft CAS confirmation and independently framed bounded diagnostics.
Source review PASS is preserved; whole-device admission acceptance is NOT PASS.
Read device/HANDOFF.txt and INDEPENDENT-LIVE-ADDENDUM.txt. No route investigation,
Mac production mutation, synthetic outbound or Apple validation retry occurred.
