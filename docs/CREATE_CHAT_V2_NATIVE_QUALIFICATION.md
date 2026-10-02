# CREATE_CHAT_V2 native Mac provider qualification

Date: 2026-10-02 UTC

Base: accepted Build 100 provider-binding commit
`11b23e4415196a4deabf417fa17b521ca37f8b23`

Decision: `NATIVE_V2_PROVIDER_BLOCKED_EXPLICIT_SENDER_BINDING`

This is public-safe evidence. No Apple identity, alias, recipient, chat,
message content, or credential is recorded.

## Outcome

The exact account can be represented in the private framework and an exact
account can be supplied to the lower send method. An internal
`IMMessage.sender` can also be prepopulated and preserved by setting
`adjustingSender:NO`.

That is not proof of the human-visible sender/caller-ID route. Retained live
evidence proves the account login handle and the effective outbound
`lastAddressedHandleID` can be different identities. The only discovered
new-chat primitive carrying that route is:

```text
IMChatRegistry
  chatForIMHandles:lastAddressedHandle:lastAddressedSIMID:
```

The selector exists on Sean's Sonoma runtime, but this qualification could not
prove that it atomically captures the supplied route, avoids account/default
fallback, preserves the route through daemon submission, and rejects an
unavailable route without substituting another alias. Consequently the helper
must not advertise `EXPLICIT_SENDER_BINDING`, and CREATE_CHAT_V2 remains
unreachable in production.

## Source authority

### Production baseline

- Macmini7,1, macOS 14.6.1 (23G93).
- BlueBubbles Server 1.9.7, source tag commit
  `c8fd02317f106f0f8deebd1cb3593bb096b2fb2e`.
- Installed `app.asar` SHA-256
  `04de35b91da68dc922a96af6f79e2663b2a1c83e7f5132adc258e3d5ef9d5d95`.
- Helper 0.0.19, source tag commit
  `cb0bccae0e0e0ab9452896fc48a5f7b1433e2f6f`.
- Installed helper SHA-256
  `685f2e36a016d7624b8fc59c313776949d0f32110b8608b5fdef89195d7b60f9`.
- The installed re-signed helper and official 0.0.19 asset have identical
  Mach-O UUID/build metadata and every non-`__LINKEDIT` section is identical
  for x86_64, arm64, and arm64e. Whole-file hashes differ because the installed
  signature/linkedit is different.

Retained Server reproduction proves structural/semantic source equivalence to
the 1.9.7 tag. The exact historical 2024 Node/package-manager/minifier and
Xcode point versions remain unknown.

### Upstream reference

- Server HEAD: `f2e2286241a7c3b6617a82b37d4afaab4df3a6b9`.
- Helper HEAD: `1ee57f3fde63f8cc5769d60cfabfe9a06fcc1069`.

Current upstream has not strengthened this path. Its new-chat flow still uses
the active global account, account-derived recipient handles,
`chatForIMHandles:`, `IMMessage sender:nil`, and ordinary
`sendMessage:`.

## Native object graph and sender distinction

```text
request sender_identity
  = human-visible caller ID / lastAddressedHandle route
  != necessarily IMAccount.loginIMHandle
  = IMMessage.sender used by Apple's internal message object
```

Retained existing-chat evidence observed `CKConversation.senderIdentifier`
and `IMChat.lastAddressedHandleID` as the same outbound work-phone route.
Separate live zero-send evidence observed `IMAccount.loginIMHandle` on the
same account but with a different identifier.

The legacy send call graph also proves:

- `adjustingSender:YES` obtains `account.loginIMHandle` and overwrites
  `IMMessage.sender`;
- `adjustingSender:NO` skips that update; and
- the supplied account is forwarded to
  `IMChatRegistry _chat:sendMessage:withAccount:`.

This makes exact account plus internal message-sender binding expressible. It
does not bind the caller-ID route.

## Actual Sonoma zero-send qualification

A privacy-hardened x86_64 native probe was built in a guarded Mac `/tmp`
directory, run, and removed. It loaded `IMFoundation`,
`IMSharedUtilities`, and `IMCore`. It invoked no creator or send method.

Important live method encodings:

| Primitive | Sonoma x86_64 encoding |
|---|---|
| `accountForUniqueID:` | `@24@0:8@16` |
| `imHandleWithID:` | `@24@0:8@16` |
| `chatForIMHandles:lastAddressedHandle:lastAddressedSIMID:` | `@40@0:8@16@24@32` |
| `lastAddressedHandleID` | `@16@0:8` |
| `_sendMessage:withAccount:adjustingSender:shouldQueue:` | `v40@0:8@16@24c32c36` |
| designated `IMMessage initWithSender:...` | `@112@0:8@16@24@32@40@48Q56@64@72@80@88@96@104` |
| `IMMessage.sender` | `@16@0:8` |

Standalone `IMAccountController` existed but returned zero accounts. This
does not mean Messages has no account; it proves the account objects are not
available to this standalone process context. Resolving them inside the loaded
Messages helper would require a helper extension or runtime injection.

Non-interactive LLDB was denied permission to debug even the temporary probe,
so exact implementation disassembly could not be recovered from this Mac.
No entitlement bypass, process attachment, helper swap, injection, or restart
was attempted.

## Exact qualification gap

The route-explicit selector's presence and ABI do not prove its semantics.
Before `EXPLICIT_SENDER_BINDING` can be emitted, evidence must prove all of:

1. account-bound recipient handles are the only account source;
2. the exact supplied last-addressed route is captured;
3. no active, best, sibling, or default account/route fallback can execute;
4. an unrelated historical chat cannot be silently retargeted;
5. downstream provider submission preserves that route; and
6. route invalidation fails rather than substituting a different sender.

There is also no discovered Apple compare-and-dispatch primitive binding a
provider revision. Validation followed by a mutating creator/send therefore
retains an unbounded daemon/global-state race unless the explicit route is
proven to be captured with fail-without-fallback semantics.

## Mutation boundary

- Last proven zero-external-mutation step: framework/selector ABI inspection,
  count-only standalone account-controller inspection, and an isolated policy
  harness with no Apple execution calls.
- First conservative Apple mutation for a new group:
  `chatForIMHandles:lastAddressedHandle:lastAddressedSIMID:` (or another
  `_createdChat...` primitive).
- Provider submission boundary:
  `IMChatRegistry _chat:sendMessage:withAccount:`.

The creator was not invoked. No `IMChat` or `IMMessage` was constructed.

## Isolated harness and failure injection

The native x86_64 qualification gate built on the actual Mac and passed 15/15
checks. It rejects incomplete requests, duplicate operation identity, wrong or
inactive account, wrong/unvetted sender route, service mismatch, recipient
mismatch, provider revision drift, old helper/ABI mismatch, unproven route
capture, possible downstream substitution, possible fallback, and unbounded
TOCTOU.

This harness is deliberately a policy model, not a provider implementation. Its
synthetic success row proves the conjunction is correctly gated; it does not
claim Apple satisfies the conjunction.

Because Phase 4 reached the prompt's mandatory stop condition:

- no helper CREATE_CHAT_V2 execution implementation was produced;
- no Server endpoint or helper protocol was enabled;
- no native operation journal or result observer was installed;
- no capability token was advertised; and
- no deployment artifact or deployment plan was prepared.

The accepted Build 100 client contract and durable fake-provider model remain
unchanged and continue to block production execution.

## Tests and compatibility

- Native Mac policy gate: 15/15 passed; zero Apple calls.
- Local probe/gate source safety tests: 8/8 passed.
- Build 100 focused group-provider tests: 71/71 passed.
- Full Flutter regression: 285/285 passed.
- Build 99 Comcast portion completed without changing writer authority; no
  protected Comcast source changed from the accepted base.

The only repository additions are this unreferenced qualification package and
documentation. Legacy `create-chat`, official BlueBubbles behavior, existing
chat sends, and the Build 99 Comcast runtime path are byte-unchanged.

## Production effects

- production server/helper replacement: 0
- Messages/BlueBubbles/helper restarts: 0
- Apple account/sender changes: 0
- group creation: 0
- message sends: 0
- `chat.db` reads/writes by the new probes: 0/0
- production installation changes: 0

Build 100 remains the single archived offline candidate and was not rebuilt or
installed.
