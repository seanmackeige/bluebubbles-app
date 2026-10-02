# NEW_GROUP_PROVIDER_CONTRACT_V1

Status: offline contract accepted; production execution disabled.

## Purpose

A new group is one provider operation that binds exact recipients, requested
service, account, sender, first-send draft, attachments, and a durable operation
identity. It does not have a physical chat GUID or ROWID until Apple creates and
the provider observes them.

The UI may use only `NewGroupProvider`. It must not call `/api/v1/chat/new` or a
helper action directly for an unresolved multi-recipient conversation.

## Provider surface

- `inspectCapabilities()`
- `resolveRecipients()`
- `readAccountIdentity()`
- `readSenderIdentity()`
- `findExactExistingGroups()`
- `reserveOperation()`
- `executeFirstSend()`
- `observeAppleResult()`
- `reconcileAmbiguousOperation()`

`reserveOperation` is side-effect free with respect to Apple messaging. The
only physical first-send boundary is `executeFirstSend`.

The immutable execution envelope is self-contained. It carries the exact sorted
normalized recipient values as well as their fingerprint, requested service,
account, sender, draft text and fingerprint, attachment intents, operation
identity, and admitted provider revision. A provider must not reconstruct the
payload from UI state or resolve recipients a second time after admission.

## Conditional authority

Admission records a revision over capability, account, sender, recipient, and
existing-group evidence. Immediately before execution the provider must return
the same revision and the same preflight evidence. Any difference terminates
the operation before execution as
`PROVIDER_AUTHORITY_CHANGED_BEFORE_EXECUTION`.

The provider must conditionally bind the exact account and sender. It must not
change Apple ID, IDS, active account, or active sender to satisfy an intent.

## Current production attestation

Read-only observation on 2026-10-01/02 proved:

- BlueBubbles Server 1.9.7 authenticated and reachable;
- mapped helper file size `1741456`;
- mapped helper SHA-256
  `685f2e36a016d7624b8fc59c313776949d0f32110b8608b5fdef89195d7b60f9`;
- exact match to retained stock helper 0.0.19;
- `create-chat`, `addresses`, `service`, `chatGuid`, `transactionId`, and
  `identifier` are present in those exact bytes;
- one helper connection, stable BlueBubbles/Messages processes, stable account
  observation, and no candidate or diagnostic staging mapping.

The exact stock action resolves handles through `activeIMessageAccount` or
`activeSMSAccount`, obtains an `IMChat`, and sends the first message. Its request
does not accept an exact account, sender, or durable operation identity. Its
response carries a transaction identity and message identifier, not provider
idempotency or conditional account authority.

Therefore the current capability is
`PRIVATE_ROUTE_ATTESTED_UNSAFE_CONTRACT`. Technical creation is proven; safe
production execution is not.

## Release boundary

The production boundary is explicitly non-executing:

- `Build100ProductionNewGroupBoundary.capabilityState` is
  `PRIVATE_ROUTE_ATTESTED_UNSAFE_CONTRACT`;
- `Build100ProductionNewGroupBoundary.executionEnabled` is `false`;
- unresolved multi-recipient composition cannot invoke `/api/v1/chat/new`;
- existing physical groups require an explicit tap and remain existing-chat
  sends;
- a future adapter must supply stable account, sender, recipient, service, and
  provider revisions plus provider-side operation idempotency before this
  classification can advance.

A later real first send requires separate human authorization for the exact
recipients, service, account, sender, draft, and attachment intent. Build 100
does not create a production group or send a production message.
