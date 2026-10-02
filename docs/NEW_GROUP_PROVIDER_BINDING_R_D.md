# New-group account/sender provider binding R&D

Date: 2026-10-02 UTC  
Base: accepted Build 100 source `ad9491cf7b98f3520d290ed97290160a2ae62c15`  
Decision: `B — PRODUCTION_BINDING_PATH_REQUIRES_BOUNDED_HELPER_SERVER_EXTENSION`

This is public-safe evidence. No raw Apple identity, credential, participant,
message, or chat content is recorded here.

## Result

The stock BlueBubbles stack does not explicitly bind account or sender for a
new-group first send. It cannot make the operation safe by observing the active
account immediately beforehand either: the helper independently reads mutable
global `activeIMessageAccount` state after the client check, and the protocol
has no compare-and-dispatch condition.

A narrow private-framework route exists, but only as a new, fail-closed
protocol. The helper must resolve an `IMAccount` by stable `uniqueID`, derive
all `IMHandle` recipients from that exact object, create the chat with the exact
last-addressed sender, verify the resulting `IMChat.account`, sender route, and
service, and dispatch in the same serialized helper action. If any equality or
private selector/ABI check fails, it must return `execution_started=false` and
perform zero physical dispatches. There is no safe fallback to stock
`create-chat`.

The Android/client-side wire contract, capability gate, typed pre-dispatch
rejection, bound receipt checking, deterministic fake provider, and durable
at-most-once server-journal model are implemented offline. No production
transport adapter is enabled. The native server/helper delta remains a Mac
change and is not installed.

## Read-only production re-attestation

Observed without restart, injection, send, chat creation, or mutation:

| Fact | Current evidence |
|---|---|
| Hardware | `Macmini7,1` |
| macOS | `14.6.1` (`23G93`) |
| BlueBubbles Server | `1.9.7`; authenticated `/api/v1/server/info` returned HTTP/application status 200 |
| Private API | enabled |
| Helper connection | connected |
| Messages process | running; PID observed only for memory-map attestation |
| Loaded helper | macOS 11+ `BlueBubblesHelper.dylib` mapped in Messages |
| Helper bytes | 1,741,456 bytes; SHA-256 `685f2e36a016d7624b8fc59c313776949d0f32110b8608b5fdef89195d7b60f9` |
| Helper semantic version | not independently exposed by the loaded dylib/runtime; the exact loaded hash is the attested identity |
| Helper actions | installed binary contains `create-chat`, `get-account-info`, `modify-active-alias`, and `activeIMessageAccount` |
| Account observation | two consecutive authenticated `get-account-info` projections were equal |
| Account identity | stock helper `strippedLogin`; exact value stable across two reads and redacted |
| Sender identity | stock helper `active_alias` / account display name; exact value stable across two reads and redacted |
| Alias evidence | 5 aliases, 5 vetted aliases; active alias was in both sets |
| Service identity in public account response | absent |

The repeated projections prove observation continuity only. The values are omitted because even stable hashes are unnecessary correlation identifiers. This does not prove that a later first send would use those values.

## Current upstream custody

Fresh read-only clones were inspected at:

- Server `f2e2286241a7c3b6617a82b37d4afaab4df3a6b9`
  (2026-07-18).
- Helper `1ee57f3fde63f8cc5769d60cfabfe9a06fcc1069`
  (2026-05-06).
- Android `e2eaced6e61eee746757a070475197bf23b671ad`
  (2026-09-05).

The current Android API still sends only `addresses`, `message`, `service`, and
the legacy method to `/api/v1/chat/new`:
[chat_api.dart](https://github.com/BlueBubblesApp/bluebubbles-app/blob/e2eaced6e61eee746757a070475197bf23b671ad/lib/services/network/api/chat_api.dart#L99-L116).

The current server private call still emits action `create-chat` with only
addresses, message, service, attributed body, effect, and subject:
[PrivateApiChat.ts](https://github.com/BlueBubblesApp/bluebubbles-server/blob/f2e2286241a7c3b6617a82b37d4afaab4df3a6b9/packages/server/src/server/api/privateApi/apis/PrivateApiChat.ts#L12-L44).

The current helper still:

1. chooses `activeIMessageAccount` or `activeSMSAccount` from the service
   string;
2. derives every recipient `IMHandle` from that chosen account;
3. calls `chatForIMHandles:` without account, sender, or operation identity;
4. constructs `IMMessage` with `sender:nil`; and
5. calls `IMChat sendMessage:`.

Primary source:
[BlueBubblesHelper.m create-chat](https://github.com/BlueBubblesApp/bluebubbles-helper/blob/1ee57f3fde63f8cc5769d60cfabfe9a06fcc1069/Messages/MacOS-11%2B/BlueBubblesHelper/BlueBubblesHelper.m#L405-L438),
[message construction and send](https://github.com/BlueBubblesApp/bluebubbles-helper/blob/1ee57f3fde63f8cc5769d60cfabfe9a06fcc1069/Messages/MacOS-11%2B/BlueBubblesHelper/BlueBubblesHelper.m#L1013-L1083).

No searched upstream path accepts `accountID`, `loginID`, caller ID, sender,
provider operation ID, or an idempotency key for new-chat creation. Existing
chat, reply, attachment, multipart, and scheduled-send paths all start with an
already selected physical chat GUID; they do not provide a new-chat account
override.

## Exact stock object graph

| Stage | Stock object/value | Selection source |
|---|---|---|
| HTTP | `/api/v1/chat/new` | client passes recipients, first message, service, legacy/private method |
| Server | `PrivateApiChat.create` | forwards the same fields; creates an internal transaction UUID |
| Helper | action `create-chat` | no account, sender, or operation identity in data |
| Account | `IMAccountController.activeIMessageAccount` | implicit mutable global/default state |
| Service | request string chooses iMessage vs SMS account branch | explicit coarse service; not an exact `IMService` identity |
| Recipients | `[selectedAccount imHandleWithID:address]` | derived from implicitly selected account |
| Chat | `IMChatRegistry chatForIMHandles:` | derived from handles; no last-addressed sender passed |
| Message sender | `initWithSender:nil` | later implicit Apple adjustment |
| Dispatch | `[chat sendMessage:messageToSend]` | chat/global state |
| Result | internal transaction resolves with last-sent message GUID | no account/sender/service proof returned |

The server's write lock serializes writes in one server process, but the
transaction ID is generated internally and is not a durable caller operation
identity. The service writes to every connected helper socket and considers
the request sent when at least one socket write succeeds:
[PrivateApiService.ts](https://github.com/BlueBubblesApp/bluebubbles-server/blob/f2e2286241a7c3b6617a82b37d4afaab4df3a6b9/packages/server/src/server/api/privateApi/PrivateApiService.ts#L303-L359).
That is not duplicate rejection and is unsafe for a non-idempotent first send.

## Account and sender enumeration

### Stock live protocol

`get-account-info` calls `activeIMessageAccount` and returns stripped login,
login handle name, aliases, vetted aliases, and display name as active alias.
It does not return:

- `IMAccount.uniqueID`;
- all active/operational iMessage accounts;
- account-to-service object relationships;
- an authoritative account-to-sender map;
- an evidence revision that the helper will conditionally enforce; or
- the account/sender actually used by a dispatch.

The adjacent stock `modify-active-alias` action mutates `IMAccount.displayName`.
It is not a binding primitive and is expressly outside this mission.

Classification:

- Account enumeration: `PRIVATE_BUT_EXISTING` in Apple objects, `UNAVAILABLE`
  through the stock BlueBubbles protocol.
- Sender enumeration: active alias plus aliases are `PRIVATE_BUT_EXISTING`, but
  a complete stable account-to-sender map and dispatch guarantee are
  `UNAVAILABLE` through the stock protocol.

### Available private objects

The shipped helper headers expose the narrow read-only resolution primitives:

- `IMAccountController.accounts`, `activeAccountsForService:`,
  `accountForUniqueID:`;
- `IMAccount.uniqueID`, `serviceName`, `loginIMHandle`, `displayName`,
  `aliases`, `vettedAliases`, `isRegistered`, `isOperational`,
  `canSendMessages`, `_isUsableForSending`;
- `IMHandle.account`, `ID`, and service;
- `IMChat.account`, `lastAddressedHandleID`, participants, and GUID;
- `IMChatRegistry chatForIMHandles:lastAddressedHandle:lastAddressedSIMID:`;
- `CKConversation.selectedLastAddressedHandle`, `senderIdentifier`,
  `sendingService`, and `sendMessage:onService:newComposition:`.

Retained V40 research also compiled and native-tested a zero-send invocation of
`-[IMChat _updateSenderForMessageIfNeeded:adjustingSender:withAccount:]` with
the exact target chat account and verified the method ABI
`v36@0:8@16c24@28`. That evidence proves a bounded sender-adjustment primitive
exists; it deliberately does not prove that the post-transform sender equals a
chosen caller ID or that any send occurred.

## Why conditional observation is not enough

The strongest stock conditional design would be:

1. read `/api/v1/icloud/account`;
2. fingerprint stripped login, aliases, vetted aliases, and active alias;
3. reserve locally;
4. read it again; then
5. call legacy `/chat/new`.

That still has a race. Between step 4 and the helper's later
`activeIMessageAccount` read, Apple account state can change. Neither the
server nor helper accepts the prior fingerprint as a condition. The socket
transaction cannot atomically compare it. Therefore the conditional route is
`UNSAFE`, even when consecutive reads match.

Helper reconnect makes this worse: the server may write the same action to
more than one connected client, and the stock result does not identify which
helper identity executed it.

## Bounded `CREATE_CHAT_V2` route

The new action must not overload `create-chat`.

### Request

```text
operation_id
account_identity             # stable IMAccount.uniqueID-derived identity
sender_identity              # exact vetted caller ID / last-addressed handle
service                      # exact requested iMessage or SMS/MMS
recipient_fingerprint
recipients                   # sorted exact normalized set
payload_identity
provider_revision
```

### Helper admission and dispatch

Run one serialized action on the Messages main queue:

1. Validate schema, exact recipient count/set/fingerprint, and supported
   service. Never omit a recipient or change service.
2. Resolve exactly one current `IMAccount` by supplied stable identity using
   `accountForUniqueID:`; require exact service, registered, operational,
   send-capable, and usable state.
3. Resolve supplied sender against that exact account's current vetted aliases.
   No `setDisplayName:` and no fallback to another alias.
4. Derive every recipient `IMHandle` using that exact account. Require each
   handle's account identity and service to match.
5. Re-read account and sender relationships. If any object, identity, service,
   alias set, or provider revision changed, return a typed rejection with
   `execution_started=false`.
6. Create/resolve the `IMChat` with the exact last-addressed sender parameter.
   Assert `chat.account.uniqueID`, `chat.lastAddressedHandleID`, participants,
   and service equal the request. Also apply the accepted existing-group policy;
   never silently reuse an unselected historical chat.
7. Construct the first message. Require the private sender-adjustment selector
   and exact ABI, apply it with the resolved account, and verify the message
   sender/account relation. A ChatKit implementation may additionally set and
   read back `selectedLastAddressedHandle`, `senderIdentifier`, and
   `sendingService`; all checks are conjunctive, not alternative fallbacks.
8. Persist/acknowledge `execution_started=true` before invoking the physical
   send. After this boundary, any missing terminal result is
   `NEW_GROUP_OUTCOME_AMBIGUOUS` and must not auto-retry.
9. Send once. Return the exact provider account, sender, service, chat GUID if
   known, message GUID if known, and terminal state.

If Apple can mutate routing outside the serialized queue after step 7 and
before step 9 despite the explicit objects, the capability must not be
advertised. A zero-send runtime probe must establish those object/readback
relationships on the exact production OS/helper build before deployment.

### Response

```text
accepted_operation_id
execution_started
provider_account_identity
provider_sender_identity
service
chat_identity_if_known
message_identity_if_known
terminal_state
reason_code
```

The offline implementation lives in
`lib/services/ui/chat/new_group_create_chat_v2.dart`. It validates the wire
request and response and models the server's durable unique-operation journal.
The existing coordinator now accepts a typed provider rejection only when it
certifies the same operation ID and zero physical dispatch. A normal exception
after the local execution-start marker remains ambiguous.

## Capability negotiation

Production requires all of these from a current handshake:

```text
server_protocol = CREATE_CHAT_V2
helper_protocol = CREATE_CHAT_V2
NEW_GROUP_V2_ACCOUNT_BOUND
NEW_GROUP_V2_SENDER_BOUND
NEW_GROUP_V2_SERVICE_BOUND
NEW_GROUP_V2_OPERATION_ID
NEW_GROUP_V2_RESULT_OBSERVATION
```

`NEW_GROUP_V2_OPERATION_ID` means durable provider-bound at-most-once admission
and no replay after dispatch may have begun. It does **not** mean Apple exposes
an idempotency key or distributed exactly-once delivery.

An old helper reports or implies `NEW_GROUP_V1_LEGACY_UNSAFE`; omission,
unknown tokens, protocol mismatch, empty evidence revisions, and server/helper
version skew all fail closed. No capability is inferred from version or macOS.

## Existing-chat comparison (Build 99)

Build 99 starts with an Apple-created physical chat GUID/ROWID. Its accepted
Comcast certificate binds exact physical chats, source account evidence,
service, current last-addressed handle, participant set, successful outbound
provenance, and one current execution generation. Immediately before the
existing-chat HTTP POST it:

- revalidates provider context and current account snapshot;
- reloads the durable certificate;
- revalidates revision and physical row/GUID; and
- sends to that exact existing chat GUID.

That path's decisive provider fact is the already-existing `IMChat`, whose
account and last-addressed route are observable and historically proven. A new
group has no physical chat object before first execution; legacy creation
chooses a mutable active account while constructing it. The existing-chat
identity system can supply the same account/sender fingerprint vocabulary, but
it cannot substitute for explicit V2 binding. No Build 99 Comcast source was
changed by this R&D.

## Operation identity and ambiguous outcome

The server extension needs a durable unique index on `operation_id` and an
exact request binding fingerprint. It must durably mark dispatch-started before
writing the helper action. The helper also rejects duplicate IDs during one
loaded lifetime. On reconnect/restart:

- `RESERVED`, with proof no helper write occurred: reject before execution and
  require a fresh human action;
- `DISPATCH_STARTED` without exact terminal evidence: preserve as
  `NEW_GROUP_OUTCOME_AMBIGUOUS` and never replay;
- exact terminal result: return the recorded result without redispatch.

Apple accepts no operation ID, so the system cannot prove distributed
exactly-once. Two genuinely different operation IDs are different
authorizations; content equality is not a safe dedupe key. Sean Edition's
durable draft invariant must therefore generate one sticky operation ID for
one captured human draft. Existing double-tap/reconnect property tests prove
the client does not mint a second ID in those paths.

## Mac change boundary

`mac_change_required: YES`.

Required production changes, not performed:

1. Server: add a separate authenticated V2 endpoint/action, durable operation
   journal, single attested helper selection, capability handshake, and exact
   result schema. Preserve every legacy endpoint.
2. Helper: add read-only account/sender enumeration and `create-chat-v2` with
   exact-object resolution, ABI checks, pre-dispatch readback, typed zero-send
   rejection, and explicit result identities. Preserve `create-chat` for
   official clients but never advertise it as V2.
3. Sean Edition: add a production transport adapter only after the complete
   V2 handshake is proven on the installed Mac stack.

Changing server code requires a BlueBubbles Server restart. Loading a changed
helper dylib requires a Messages/helper reload, which in this deployment means
a Messages restart. Neither occurred.

Rollback is restore the exact Server 1.9.7 bundle and helper SHA-256 above,
then perform the same explicit restarts during an authorized maintenance
window. The official BlueBubbles client remains compatible because legacy
routes are additive and unchanged. Build 99 remains compatible because it uses
existing-chat endpoints only.

## Offline verification

- Focused new-group suite: 71 tests passed after the V2 additions.
- New V2 tests cover complete handshake, old helper, omitted capability,
  account/sender/service request binding, exact recipients/fingerprint,
  bound response, zero-dispatch rejection, duplicate operation, rebinding,
  restart ambiguity, and 64-operation repeated-reserve/dispatch property runs.
- Fake-provider additions cover explicit binding success, account unavailable,
  sender unavailable, account change, sender change, service change, operation
  duplicate, capability mismatch, old helper, new helper, and TOCTOU rejection.
- Existing Build 100 tests continue to cover attachments, recipient omission
  and addition, service downgrade, wrong observed account/sender, timeout after
  execution, reconnect, and double tap.

- Full repository suite: 285 tests passed.
- Build 99 logical-conversation and Comcast regression: 209 tests passed.
- Static analysis of every changed Dart source and test: no issues.

No APK was packaged or rebuilt.

## Adversarial answers

1. **Different sender than admitted?** Stock: yes, unprevented. V2: exact
   helper resolution plus chat/message/ChatKit readback; mismatch is zero send.
2. **Different account than admitted?** Stock: yes, due active-account lookup.
   V2: handles, chat, message transform, and response all bind one exact account
   object/identity; mismatch is zero send.
3. **Global/default race?** Stock conditional observation is unsafe. V2 must
   not depend on the global default after resolving explicit objects; the
   zero-send runtime probe must confirm serialization/readback on Sonoma.
4. **Helper reconnect alters identity?** Legacy can fan out. V2 requires one
   attested helper session and treats disconnect after dispatch-start as
   ambiguous, never as a retry cue.
5. **Two operation IDs for one draft?** Provider cannot infer human sameness
   from identical content. The sticky client operation identity is mandatory;
   content dedupe would suppress legitimate repeated messages.
6. **One operation ID twice?** Durable unique reservation and state transition
   permit one dispatch boundary. Property tests keep dispatch count at one.
7. **Old helper lies by omission?** Omission is failure. The full token set and
   helper evidence revision are required.
8. **Version skew bypass?** No. Both protocol strings and all guarantees must
   match; version numbers are not capability evidence.
9. **Official BlueBubbles unaffected?** Yes in the design: legacy endpoints
   remain unchanged. No official production files were modified in this R&D.
10. **Build 99 Comcast disturbed?** No new-group files are outside the isolated
    provider contract/test surface; full and targeted regression must remain
    green before this branch is accepted.

## Release gate

Production new-group execution remains blocked. Before any Mac deployment:

1. implement and native-build the additive server/helper delta;
2. run a zero-send Sonoma capability probe proving exact account, sender,
   service, recipient-handle, chat, and message relations;
3. repeat failure injection across helper disconnect and server crash;
4. obtain independent adversarial review; and
5. separately obtain human authorization for any real recipient set and first
   message.

This R&D created no production group, sent no production message, changed no
Apple account/sender state, restarted no process, and did not write `chat.db`.
