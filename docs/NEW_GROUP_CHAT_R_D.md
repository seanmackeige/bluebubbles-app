# Sean Edition new-group creation R&D

Status: `R&D_COMPLETE_SAFE_EXECUTION_BLOCKED_PROVIDER_CONTRACT`

This investigation is read-only with respect to the Mac, Messages, BlueBubbles
Server, the helper, Apple IDs, sender/account state, and `chat.db`. No production
group or message was created. The offline policy in
`lib/services/ui/chat/new_group_conversation.dart` is deliberately disconnected
from all transports.

## Exact failure trace

The displayed sentence is server-generated, not Android-generated.

1. Sean Edition's `ChatCreatorController.sendMessage` collects the selected
   addresses and requested service. Its current existing-chat resolution also
   changes the selected service to SMS if any selected contact reports SMS and
   returns the first participant-set match. Neither behavior is safe for new
   group admission.
2. `ChatApi.create` sends `POST /api/v1/chat/new` with `addresses`, `message`,
   `service`, and `method`. The method is `private-api` only when the Android
   `enablePrivateAPI` setting is true; otherwise it is `apple-script`.
3. Server routing is `HttpRoutes` -> `ChatValidator.validateCreate` ->
   `ChatRouter.create` -> `ChatInterface.create`.
4. `ChatInterface.create` throws the exact error when all three predicates are
   true: `method == 'apple-script'`, `isMinBigSur`, and `addresses.length > 1`.
5. `isMinBigSur` is `macosVersion >= 11.0`.
6. Android renders the server's raw error inside its own `Failed to create
   chat!` dialog.

The observed error therefore proves that this request reached the server as an
AppleScript multi-recipient creation request on Big Sur or newer. It does not
prove that every modern creation mechanism is unavailable.

Local source anchors:

- `lib/app/layouts/chat_creator/chat_creator_controller.dart`
- `lib/services/network/api/chat_api.dart`
- BlueBubbles Server `packages/server/src/server/api/interfaces/chatInterface.ts`
- BlueBubbles Server `packages/server/src/server/env.ts`

## Historical reason and current upstream

The guard was introduced in upstream server commit
`fbe31c05add8867fc62a3c02421f0fd4c18d35f8` on 2022-04-09, after commit
`36e185654daef32805b5a241f3e3464e587616f6` first added the Big Sur check.
Upstream source says chat creation does not work on Big Sur+ and works around
that limitation for one recipient by sending to an inferred direct-chat GUID.
The AppleScript generator changes `make new text chat` before Big Sur to
`make new chat` on Big Sur+, but the group path is still guarded.

Current official source was inspected at:

- server `f2e2286241a7c3b6617a82b37d4afaab4df3a6b9`, version 1.9.9;
- Android/client `e2eaced6e61eee746757a070475197bf23b671ad`;
- documentation `4bcb6e318412d150dca0fd35558a05b841c63503`;
- helper `1ee57f3fde63f8cc5769d60cfabfe9a06fcc1069`, with tags through 0.0.21.

Server 1.9.9 retains the same guard and creation implementation as 1.9.7; the
only `chatInterface.ts` difference from tag `v1.9.7` is unrelated group-icon
filename handling. The current client still calls `/chat/new` and chooses the
method from its local Private API toggle.

Upstream did add a technically functional modern route. `private-api` invokes
the helper's `create-chat` action. The helper resolves every address against
the active iMessage or SMS account, gets an `IMChat` from `IMChatRegistry`, and
sends the first message through that chat. The server receives a message GUID,
waits for that message and its chat to appear in Messages data, then returns
the Apple-created chat. Current docs list chat creation as a Private API
feature, but say the helper was tested only through Ventura and warn that
helper exceptions can crash Messages and disable Private API until Messages is
restarted.

Official upstream references:

- <https://github.com/BlueBubblesApp/bluebubbles-server/blob/master/packages/server/src/server/api/interfaces/chatInterface.ts>
- <https://github.com/BlueBubblesApp/bluebubbles-app/blob/master/lib/services/network/api/chat_api.dart>
- <https://github.com/BlueBubblesApp/bluebubbles-helper/blob/master/Messages/MacOS-11%2B/BlueBubblesHelper/BlueBubblesHelper.m>
- <https://docs.bluebubbles.app/private-api>

## Operation and OS matrix

| Operation | Catalina 10.15 | Big Sur 11 through Sonoma 14 | Sequoia 15 |
|---|---|---|---|
| New 1:1 iMessage/SMS | AppleScript can make a physical chat before an optional send | AppleScript requires the first message and sends to an inferred direct GUID; Private API also exists | Same current source path; runtime not verified here |
| New iMessage group | AppleScript `make new text chat`; message can follow | AppleScript blocked; Private API/helper obtains `IMChat` and performs the first send | Same `MacOS-11+` helper source; runtime not verified here |
| New SMS/MMS group | AppleScript path exists as service `SMS` | Private helper selects `activeSMSAccount`; no MMS-specific or no-fallback safety contract is exposed | Source-present, runtime and semantics unverified |
| Add/remove participant | Private API for an existing group | Private API for an existing group | Source-present, runtime unverified |
| Existing group send | Existing message-send route | Existing message-send route | Existing message-send route |

There is no separate algorithm for Monterey, Ventura, or Sonoma group
creation. All use the macOS 11+ helper branch. Ventura changes some AppleScript
account syntax elsewhere, but not this guarded group-creation decision.

## Read-only Mac capability inventory

Authenticated read-only BlueBubbles API checks returned:

- macOS 14.6.1;
- BlueBubbles Server 1.9.7;
- `private_api: true`;
- `helper_connected: true`.

Build 100 continuation re-attested the live path through the established
read-only observer. The exact mapped helper is the retained stock 0.0.19 binary:
size `1741456`, SHA-256
`685f2e36a016d7624b8fc59c313776949d0f32110b8608b5fdef89195d7b60f9`.
`create-chat` and its request/result schema strings are present in those exact
bytes. One helper connection was present, process and account observations were
stable, and no candidate or diagnostic staging image was mapped. This supersedes
the earlier unavailable-byte statement.

| Mechanism | Classification | Finding |
|---|---|---|
| BlueBubbles public HTTP API | `SUPPORTED_FACADE` | `/api/v1/chat/new` exists, but its Big Sur+ AppleScript group route is deliberately unavailable |
| BlueBubbles Private API | `PRIVATE_BUT_EXISTING` | Server reports it enabled; upstream routes creation to the helper |
| Connected helper bundle | `PRIVATE_ROUTE_ATTESTED_UNSAFE_CONTRACT` | Exact stock 0.0.19 bytes and `create-chat` are attested, but account/sender binding and operation idempotency are absent |
| Messages AppleScript group creation | `UNAVAILABLE_MODERN` | Upstream blocks it for every macOS version >= 11.0 |
| Private Messages frameworks | `PRIVATE_BUT_EXISTING` | `IMAccountController` and `IMChatRegistry` are used by the helper; direct new integration is not justified |
| Direct experimental helper/private-framework bypass | `UNSAFE` | Would bypass upstream exception/crash precautions without account or replay safety |
| `chat.db` writes | `PROHIBITED` | Observation/provenance only; no table mutation is part of any route |

## Apple creation semantics

On Catalina's AppleScript path, a chat object can be created before sending a
message. On the modern helper path, the helper first obtains an in-memory
`IMChat`, but `/chat/new` requires a message and the server does not establish a
canonical result until the outbound message GUID is observed with an
Apple-created chat. Sean Edition must therefore treat modern group creation as
one operation:

`exact recipients + service/account + first outbound message -> observed Apple chat`

It must not invent or persist a physical chat GUID/ROWID before Apple creates
and the provider observes it.

## Why the upstream modern route is not yet safe for Sean Edition

The current helper chooses `activeIMessageAccount` or `activeSMSAccount`
internally. The request cannot name and conditionally bind the exact account or
sender. Neither server nor helper accepts a durable operation identity or
provides conditional idempotency. A timeout after helper invocation can mean
the first message and group exist even though Android received no result.
Replaying can duplicate the first message, the group, or both. `/chat/new` also
does not carry the Android attachment intent as one atomic creation operation.

The provider capability `CAN_CREATE_IMESSAGE_GROUP` must therefore be based on
explicit evidence, not macOS version. Production admission requires all of:

- requested service supported with no fallback;
- helper connection and exact `create-chat` action attestation;
- exact recipient capability evidence still current;
- explicit account and sender binding;
- provider-enforced operation identity/idempotency;
- Apple chat and first-message observation;
- attachment support when an attachment is part of the first-send intent.

Sean's stack currently proves only the technical Private API/helper connection,
not the account-binding and idempotency contract. Safe execution is blocked.

## Offline implementation

`new_group_conversation.dart` implements a transport-disconnected policy for:

- `NEW_LOGICAL_CONVERSATION_INTENT_V1`, with the exact externally normalized
  recipient set, requested service, expected account/sender, draft,
  attachments, content revision, and unique operation ID;
- explicit, expiring provider, recipient, and account evidence;
- no self, duplicate, omission, addition, stale resolution, or silent service
  fallback;
- exact existing-group comparison across recipients, service, and account;
- explicit selection for one current, one historical, or multiple exact
  physical matches;
- serializable admission and execution-started records;
- one dispatch reservation per operation;
- `outcomeAmbiguous` after any interruption once execution starts;
- read-only observation may later resolve an ambiguous operation, but can never
  grant a second dispatch;
- success only after exactly one terminal first message and an exact
  Apple-created chat/account/sender/recipient/content match.

Build 100 adds the awaited crash-durable journal, narrow provider interface,
full operation state machine, provider-revision revalidation, deterministic
fake provider, strong Apple result reconciliation, and restart recovery. New
Message imports only the fail-closed capability gate: unresolved groups cannot
reach `/chat/new`. No real BlueBubbles provider execution adapter is wired
because the currently attested stock helper still lacks conditional account,
sender, and operation-ID authority.

## Adversarial review

The independent post-implementation pass is banked in
`NEW_GROUP_BUILD100_ADVERSARIAL_REVIEW.md`. All ten required challenges pass for
the offline fail-closed contract and fail closed for production execution.

The production UI corrections are deliberately narrow:

- requested iMessage is no longer auto-switched to SMS from contact status;
- a multi-recipient physical match is never auto-activated;
- only an explicit tap selects an existing group and its service;
- every unresolved multi-recipient send returns bounded capability truth before
  the sole raw create call;
- the real provider adapter remains absent and
  `Build100ProductionNewGroupBoundary.executionEnabled` remains `false`.

The fresh pass added direct pre-dispatch drift injections for recipient,
account, sender, and service evidence. Each terminates as
`PROVIDER_AUTHORITY_CHANGED_BEFORE_EXECUTION` with zero calls to
`executeFirstSend`. It also corrected the execution envelope to carry the
actual normalized recipients, draft text, and attachment intent alongside their
fingerprints, and now binds the helper message identity to the observed Apple
message GUID. Crash injection covers every durable boundary from draft through
terminal success.

Review result: `PASS_FOR_OFFLINE_FAIL_CLOSED_CONTRACT` and
`BLOCKED_FOR_PRODUCTION_EXECUTION`.

Verification:

- focused new-group suites: 56/56 passed;
- Build 99 Comcast logical-conversation bank: 209/209 passed;
- complete Flutter regression: 270/270 passed;
- changed-file analysis: zero errors and zero warnings; six incumbent
  information findings remain on unchanged creator lines;
- source audit: the sole raw create call is after the group gate and remains
  available only to a new 1:1; explicit existing groups use their incumbent
  existing-chat path;
- no Comcast logical-conversation or writer-authority source changed.

## Candidate policy

The accepted production baseline remains Build 99 at
`bbbba0d2cd18de294b4f4ca223331eaa7241e221`. Repository and archive truth leave
Build 100 as the next eligible immutable Sean Edition number. The offline
release gates permit at most one signed `2.0.0+100` candidate with Android
versionCode `20002100`, while real new-group execution stays disabled. A
zero-send S24 installation is unnecessary for provider-contract proof and is
not part of this release gate.
