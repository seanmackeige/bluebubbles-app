# Build 100 new-group adversarial review

Date: 2026-10-02

Result: `PASS_FOR_OFFLINE_FAIL_CLOSED_CONTRACT` and
`BLOCKED_FOR_PRODUCTION_EXECUTION`.

This was a fresh source and test pass after implementation. It did not invoke a
BlueBubbles create endpoint, helper action, Messages framework, or `chat.db`
write.

## Challenges

1. **Can two taps create two groups?** No in the offline contract. One operation
   identity is bound to one immutable payload, concurrent calls serialize, the
   journal returns the existing operation, and the 32-operation property test
   observed one `executeFirstSend` invocation per identity.
2. **Can process death create a second first send?** No automatic replay is
   available after the durable `EXECUTION_STARTED` marker. Restart maps that
   state to `OUTCOME_AMBIGUOUS`; recovery after provider receipt, Apple result,
   and terminal persistence was injected separately.
3. **Can helper timeout create a retry?** A pre-execution timeout performs zero
   dispatches. A timeout after the physical boundary becomes
   `NEW_GROUP_OUTCOME_AMBIGUOUS`; repeated execute calls do not reach the fake
   helper again.
4. **Can a recipient disappear between admission and execution?** The provider
   resolver is reread immediately before dispatch. A distinct injected
   disappearance changes both exact human intent and provider revision and
   terminates with `PROVIDER_AUTHORITY_CHANGED_BEFORE_EXECUTION` at zero
   dispatches.
5. **Can sender or account drift silently?** Both identities are explicit,
   expiring evidence and part of the provider revision. Separate account and
   sender drift injections were rejected before execution with zero dispatches.
6. **Can iMessage silently downgrade?** Requested service is immutable in the
   operation binding and envelope. The prior UI auto-switch to SMS was removed.
   A service-capability change blocks before execution; an observed SMS/MMS
   result for an iMessage intent remains ambiguous and cannot bind.
7. **Can an old exact-set group be reused accidentally?** No unresolved
   multi-recipient set auto-activates a physical chat. Current, historical, and
   multiple exact matches require explicit selection; only a tap on a specific
   existing result activates its incumbent existing-chat path.
8. **Can Apple succeed while Sean Edition reports failure and later retries?**
   It may report an unknown outcome, but it cannot retry automatically. Strong
   read-only reconciliation can prove success and bind once; otherwise the
   operation remains ambiguous.
9. **Can text equality bind the wrong physical result?** Text is absent from the
   strong observation key. Binding requires operation and provider request IDs,
   message and chat GUID/ROWID, exact participants, service, account, sender,
   time ordering, from-me state, and terminal send state.
10. **Can Build 100 regress Build 99 Comcast behavior?** New-group execution is
    isolated in new files and a fail-closed New Message gate. No Comcast
    logical-conversation or writer-authority source changed. Its dedicated
    seven-file bank passed 209/209 and the full suite passed 270/270.

## Review findings and resolution

The fresh pass required direct tests for recipient, account, sender, and service
drift between admission and execution rather than relying on one generic
provider-revision test. Four deterministic injections were added; all terminate
before `executeFirstSend` with zero physical execution.

It also found that the first draft of the execution envelope carried recipient
and draft fingerprints but not the actual normalized recipient values or draft
text. That interface could not drive a real provider without unsafe out-of-band
UI state. The envelope is now self-contained, the fake executes only from it,
and the durable helper message identity must equal the Apple message GUID.
Policy text was completed for strong correlation and the explicit non-executing
production boundary.

The stock Server 1.9.7/helper 0.0.19 route remains unsuitable for production
because its `create-chat` request cannot bind an exact account, sender, or
durable idempotency identity. Build 100 therefore exposes only bounded
capability truth. `Build100ProductionNewGroupBoundary.executionEnabled` is
`false`, and unresolved groups cannot reach the raw create endpoint.

## Verification

- focused new-group suites: 56/56 passed;
- Build 99 Comcast logical-conversation bank: 209/209 passed;
- complete Flutter suite: 270/270 passed;
- changed-file analysis: zero errors and zero warnings; six incumbent
  information-level findings remain on unchanged lines in the creator;
- raw create source audit: the sole production call is after the group gate and
  is reachable only for a resolved existing chat or a new 1:1;
- production group created: no;
- production message sent: no.
