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

The safe UI state is:

`Group creation unavailable — safe provider operation contract missing`

More specific recipient failures take precedence, such as:

`Recipient unavailable for iMessage`

No private-framework implementation detail is shown to the user.
