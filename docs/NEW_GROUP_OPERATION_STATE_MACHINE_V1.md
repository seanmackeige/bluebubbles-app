# NEW_GROUP_OPERATION_STATE_MACHINE_V1

Status: implemented and offline-proven.

## Canonical states

```text
DRAFT
  -> VALIDATED
  -> ADMITTED
  -> EXECUTION_RESERVED
  -> EXECUTION_STARTED
  -> APPLE_RESULT_OBSERVED
  -> TERMINAL_SUCCESS
```

Terminal alternatives are `PRE_EXECUTION_REJECTED` and
`OUTCOME_AMBIGUOUS`.

Every boundary is a complete awaited journal replacement. The journal stores
the original intent, operation-binding fingerprint, admitted provider revision,
admission evidence revision, dispatch count, provider reservation/request
identities, Apple result, and an ordered transition history.

## Operation identity

One operation ID is bound to a fingerprint of:

- sorted exact normalized recipients;
- requested service;
- account identity;
- sender identity;
- text and attachment-intent fingerprint.

Reusing the ID with changed input is terminally rejected. Concurrent UI taps
serialize through one coordinator lock and return the same durable operation.

## Physical boundary

The operation is persisted as `EXECUTION_STARTED` with dispatch count one
before `executeFirstSend` can be invoked. From that point automatic replay is
forbidden. A provider return, disconnect, timeout, process death, or malformed
receipt cannot increase the dispatch count.

This proves at-most-once dispatch by Sean Edition. It does not claim
distributed exactly-once delivery by Apple.

## Restart recovery

- `EXECUTION_RESERVED` becomes `PRE_EXECUTION_REJECTED`; no first send began.
- `EXECUTION_STARTED` becomes `OUTCOME_AMBIGUOUS`; no replay occurs.
- `APPLE_RESULT_OBSERVED` becomes `TERMINAL_SUCCESS`; no provider call occurs.
- earlier states remain non-executing until an explicit caller action.
