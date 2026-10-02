# NEW_GROUP_EXISTING_GROUP_SELECTION_POLICY_V1

Status: implemented and offline-proven.

Before admission, the provider performs a read-only search for physical groups
whose exact external participant fingerprint, service, and account match the
new intent. Sender and provider revision remain separate execution gates.

The result is exactly one of:

- `NO_EXACT_GROUP`;
- `ONE_CURRENT_EXACT_GROUP`;
- `ONE_HISTORICAL_EXACT_GROUP`;
- `MULTIPLE_EXACT_GROUPS`.

## Behavior

`NO_EXACT_GROUP` may proceed to the remaining provider gates.

Every other state requires explicit selection. Sean Edition does not choose the
first database row, the newest row, a title match, or the most recently active
row. It does not silently reuse a historical exact-set conversation when the
human intent is to create a new one.

In New Message, a multi-recipient set no longer auto-activates a matching chat.
An existing result is activated only when the user taps that physical chat.
That path remains an existing-chat send and does not enter the new-group
first-send state machine.

## Matching constraints

- Recipient normalization is provider-authoritative.
- Counts and set members must both be exact.
- Duplicate normalized recipients are invalid, not deduplicated.
- Service must match; iMessage and SMS/MMS are never interchangeable.
- Account must match.
- Historical status is retained in the classification.

Read identity never grants write authority. The Build 99 Comcast logical
conversation and writer-authority machinery remains independent and unchanged.
Selecting an existing group routes through its incumbent existing-chat send
path; it never grants or borrows new-group first-send authority.
