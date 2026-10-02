# NEW_GROUP_PROVIDER_CAPABILITY_MODEL_V1

Status: implemented.

macOS version alone is never a new-group capability. The model reports one of:

1. `GROUP_CREATE_UNAVAILABLE`
2. `APPLE_SCRIPT_SINGLE_ONLY`
3. `PRIVATE_ROUTE_PRESENT_UNATTESTED`
4. `PRIVATE_ROUTE_ATTESTED_UNSAFE_CONTRACT`
5. `PRIVATE_ROUTE_SAFE_OFFLINE`
6. `PRIVATE_ROUTE_READY_FOR_HUMAN_AUTHORIZED_EXECUTION`

## Evidence dimensions

Capability evidence includes:

- server version and evidence revision;
- Private API enabled state;
- helper connection;
- exact helper action attestation;
- explicit server and helper protocol identities;
- the complete account, sender, service, operation-ID, and result-observation
  capability token set;
- requested iMessage or SMS/MMS group support;
- explicit account binding;
- explicit sender binding;
- operation-ID idempotency;
- exact Apple result observation;
- first-send attachment support when required;
- observation and expiry times.

Recipient, account, sender, and existing-group evidence are evaluated in
addition to capability and are included in the admitted provider revision.

## Current classification

The mapped stock helper 0.0.19 and `create-chat` action are attested, so the
route is no longer merely present or assumed from a settings boolean. However,
the exact action selects the active Apple account internally and has no
operation identity. Current classification is therefore
`PRIVATE_ROUTE_ATTESTED_UNSAFE_CONTRACT`.

The bounded successor protocol is `CREATE_CHAT_V2`. Production requires both
the server and helper to report that exact protocol plus:

- `NEW_GROUP_V2_ACCOUNT_BOUND`
- `NEW_GROUP_V2_SENDER_BOUND`
- `NEW_GROUP_V2_SERVICE_BOUND`
- `NEW_GROUP_V2_OPERATION_ID`
- `NEW_GROUP_V2_RESULT_OBSERVATION`

An old helper is explicitly `NEW_GROUP_V1_LEGACY_UNSAFE`. Missing tokens,
unknown protocol, empty evidence revision, or server/helper skew fail closed.
No capability is inferred from a version number.

`NEW_GROUP_V2_OPERATION_ID` means durable at-most-once provider admission and
no automatic replay after physical execution may have begun. Apple exposes no
operation-id conditional primitive, so it is not a distributed exactly-once
claim.

The 2026-10-02 provider-binding R&D remains classification B: the offline wire
contract and deterministic implementation are complete, but the current
production server/helper do not implement or advertise V2. See
`NEW_GROUP_PROVIDER_BINDING_R_D.md`.

The safe UI state is:

`Group creation unavailable — safe provider operation contract missing`

More specific recipient failures take precedence, such as:

`Recipient unavailable for iMessage`

No private-framework implementation detail is shown to the user.
