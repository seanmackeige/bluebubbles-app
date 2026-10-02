import 'package:bluebubbles/services/ui/chat/logical_conversation_identity.dart';
import 'package:bluebubbles/services/ui/chat/logical_membership_refresh.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('membership refresh admits only the exact logical conversation', () {
    expect(
      shouldRefreshLogicalMembershipProjection(
        eventData: <String, dynamic>{'logicalId': 'logical-a'},
        currentLogicalId: 'logical-a',
      ),
      isTrue,
    );
    expect(
      shouldRefreshLogicalMembershipProjection(
        eventData: <String, dynamic>{'logicalId': 'logical-b'},
        currentLogicalId: 'logical-a',
      ),
      isFalse,
    );
    expect(shouldRefreshLogicalMembershipProjection(eventData: null, currentLogicalId: 'logical-a'), isFalse);
    expect(
      shouldRefreshLogicalMembershipProjection(
        eventData: <String, dynamic>{'logicalId': 'logical-a'},
        currentLogicalId: null,
      ),
      isFalse,
    );

    const rawCertificateId = 'LGC_V2_exact-certificate-id';
    final wrappedApplicationId = LogicalConversationId.certified(rawCertificateId).value;
    final rawEvent = <String, dynamic>{'logicalId': rawCertificateId};
    expect(shouldRefreshLogicalMembershipProjection(eventData: rawEvent, currentLogicalId: rawCertificateId), isTrue);
    expect(
      shouldRefreshLogicalMembershipProjection(eventData: rawEvent, currentLogicalId: wrappedApplicationId),
      isFalse,
    );
  });

  test('missing certified member arrival advances only its stable logical projection', () {
    final tracker = LogicalMembershipAvailabilityTracker();

    expect(
      tracker.observe(<String, String>{'logical-a': 'one-of-two', 'logical-b': 'complete-b'}, reportChanges: false),
      isEmpty,
    );
    expect(
      tracker.observe(<String, String>{'logical-a': 'two-of-two', 'logical-b': 'complete-b'}, reportChanges: true),
      <String>{'logical-a'},
    );
    expect(
      tracker.observe(<String, String>{'logical-a': 'two-of-two', 'logical-b': 'complete-b'}, reportChanges: true),
      isEmpty,
    );
  });

  test('cold-start seeding and unrelated new identities do not fabricate advancement', () {
    final tracker = LogicalMembershipAvailabilityTracker();
    tracker.observe(<String, String>{'logical-a': 'partial-a'}, reportChanges: false);

    expect(
      tracker.observe(<String, String>{'logical-a': 'partial-a', 'logical-new': 'complete-new'}, reportChanges: true),
      isEmpty,
    );
  });
}
