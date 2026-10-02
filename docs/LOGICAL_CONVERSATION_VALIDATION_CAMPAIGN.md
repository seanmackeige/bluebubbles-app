# Logical Conversation P0/P1 Validation Campaign

Date: 2026-10-02

Scope: offline, test-only validation of Sean Edition logical conversation identity and projection behavior

Production mutation: none

## Result

PASS — 15/15 focused property, failure-injection, and performance tests passed.

Command:

```text
flutter test --reporter expanded \
  test/logical_conversation_property_campaign_test.dart \
  test/logical_conversation_performance_campaign_test.dart
```

The tests are pure in-memory Dart/Flutter tests. They do not start application services, open the production database,
contact a server, create a chat, send a message, access a device, or contact the Mac.

## Coverage

| Priority | Surface | Evidence |
|---|---|---|
| P0 | Member/candidate ordering | 64 deterministic candidate permutations produce the same certificate revision and decisions. |
| P0 | Message/relationship ordering | 32 shuffled timeline permutations preserve canonical ordering, exact duplicate suppression, and relationship targets. |
| P0 | Canonical vs incremental projection | 4,000 seeded insert/update/delay/duplicate/remove operations are compared with a fresh canonical rebuild at every checkpoint. |
| P0 | Duplicate/delayed/out-of-order events | Exact duplicates are unchanged; delayed updates reorder canonically; conflicting provenance throws before mutation. |
| P0 | Candidate arrival/rejection | Complete candidates admit deterministically; different-set candidates, duplicate universes, and stale pairwise proof fail closed. |
| P0 | Restart/cache loss/reconnect | Cache loss reconstructs the exact projection; certificate/member drift invalidates cache; identical authority after reconnect restores the epoch. |
| P0 | Dispatch uncertainty | A persisted dispatch reservation survives ledger reconstruction and transitions to `outcomeUnknown`; logical retry and socket-echo completion remain disabled. |
| P1 | Identity/list/timeline | Random local ROWID allocations still collapse only certified members to the presentation row and retain ordinary entries. |
| P1 | Ordinary singleton equivalence | 500 ordinary identities match their explicit legacy bridge and remain distinct from adjacent physical sources. |
| P1 | Unread | 24 sources × 21 revisions plus duplicate terminal observations converge identically under 24 shuffled event orders. |
| P1 | Notification/search/media | Snapshot order is canonical; notification identity is stable; exact source/message anchors survive round trip; tampering fails closed. |
| P1 | Draft | Serialized draft content, attachment intent, reply provenance, and action identity survive restart; a new process requires one authority re-arm without changing human intent. |
| P1 | Larger N and bounded collections | Maximum supported 256 members, 512 search results, and 512 media items round trip with identical fingerprint. |
| P1 | Long history, reactions, attachments | 50,000 mixed events across 64 sources include reaction and attachment classes; incremental stress uses 20,000 events across 96 sources. |

## Failure injection

- Same event GUID with different physical provenance: rejected with `StateError`; prior projection remains intact.
- Newly admitted member or execution-generation event: incremental mutation is refused with `fullRebuildRequired`.
- Older provider observation completes after a newer observation begins: rejected as out of order.
- Duplicate candidate evidence: the entire reconciliation universe is rejected without partial admission.
- Sequential candidate with stale pairwise proof: rejected until evidence covers the newly admitted member.
- Certificate revision drift or member-binding drift: projection cache is incompatible.
- Process restart after dispatch reservation: journal state survives and can become `outcomeUnknown`; duplicate admission remains rejected.
- Notification identity tampering inside a persisted snapshot: deserialization fails closed.

## Performance evidence

Measurements are wall-clock time from the focused debug-mode test process on the local qualification host. Thresholds
are regression tripwires, not product latency claims.

| Benchmark | Workload | Result | Threshold | Status |
|---|---:|---:|---:|---|
| Canonical rebuild | 50,000 unique events + 5,000 exact duplicates, 64 sources | 328 ms | < 8,000 ms | PASS |
| Incremental projection | 20,000 shuffled events, 96 sources | 3,388 ms | < 8,000 ms | PASS |
| Maximum bounded snapshot | 256 members, 512 search results, 512 media items, 479,921-byte JSON round trip | 235 ms | < 4,000 ms | PASS |

The incremental result is intentionally measured with shuffled insertion, which exercises list insertion costs rather
than the favorable append-only case. The broad thresholds absorb debug runtime and shared-host variance while still
detecting order-of-magnitude regressions.

## Fixture and ROWID custody

- All new identities, addresses, message IDs, and local row numbers are synthetic and public-safe.
- The tests bind the banked sanitized GUID-fingerprint trust anchor to many generated local ROWID allocations.
- No production source imports a test fixture or the campaign files.
- A production-source scan found no positive dependency on retained fixture ROWIDs. The release gate reconstructs its
  forbidden legacy fixture-specific schema marker from neutral code points so it can reject stale AOT output without
  retaining provider coordinates in production source.

## Limits

- These are deterministic offline model and value-object tests, not UI frame-time or device memory measurements.
- They do not prove server/provider delivery, Apple account state, or production database behavior.
- They do prove that the tested read-side identity/projection and local admission primitives remain deterministic,
  reconstructible, provenance-preserving, and fail-closed under the specified campaign.
