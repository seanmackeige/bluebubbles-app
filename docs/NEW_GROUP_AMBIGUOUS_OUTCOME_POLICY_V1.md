# NEW_GROUP_AMBIGUOUS_OUTCOME_POLICY_V1

Status: implemented and offline-proven.

## Trigger

After `EXECUTION_STARTED`, any missing terminal proof produces
`NEW_GROUP_OUTCOME_AMBIGUOUS`, including:

- helper or server timeout/disconnect;
- process death;
- missing or delayed Apple observation;
- provider receipt identity mismatch;
- wrong account, sender, service, or participant set in observed Apple truth;
- incomplete chat/message relationship evidence.

The draft, attachment intent, operation identity, provider revision, transition
history, and any provider receipt are retained.

## Mandatory behavior

An ambiguous operation is never submitted to `executeFirstSend` again.
Reconnect, double tap, app restart, and repeated UI entry all return the same
durable operation.

Only read-only reconciliation is allowed. It returns one of:

- `PROVEN_SUCCESS`;
- `PROVEN_NOT_EXECUTED`;
- `STILL_AMBIGUOUS`.

`PROVEN_SUCCESS` requires the same strong Apple result contract used by the
normal path. `STILL_AMBIGUOUS` makes no state change. Identical evidence must
produce an identical result and no second local binding.

`PROVEN_NOT_EXECUTED` closes the old operation as pre-execution rejected. It
does not reactivate that operation. A later dispatch requires a fresh human
action, a fresh operation identity, current provider evidence, and any separate
production authorization then in force.

## Strong correlation

Content equality is not a primary identity. Correlation requires operation and
provider request identities, exact participant fingerprint, service, account,
sender, execution time ordering, message GUID/ROWID, chat GUID/ROWID, and the
observed Apple message-to-chat relationship. A matching text body alone cannot
bind an operation or turn ambiguity into success.
