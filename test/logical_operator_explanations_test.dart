import 'package:bluebubbles/services/ui/chat/logical_operator_explanations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('raw provider predicates map to bounded operator explanations', () {
    expect(logicalRouteOperatorReason('CURRENT_SOURCE_BINDING_CONTRADICTION'), 'conversation source changed');
    expect(logicalRouteOperatorReason('CURRENT_GENERATION_ACCOUNT_CONTRADICTION'), 'account or sender changed');
    expect(
      logicalRouteOperatorReason('INTENDED_EXTERNAL_PARTICIPANT_SET_CERTIFICATE_MISMATCH'),
      'participant set changed',
    );
    expect(logicalRouteOperatorReason('ROUTE_NOT_PROVEN_EXPANDED_SET_AMBIGUOUS'), 'participant set changed');
    expect(logicalRouteOperatorReason('SOMETHING_NEW_AND_UNRECOGNIZED'), 'route could not be verified');
  });

  test('true multi-writer ambiguity is described without exposing its predicate', () {
    expect(
      logicalRouteOperatorReason(
        'CURRENT_ROUTE_EVIDENCE_UNAVAILABLE',
        authorityState: 'SEND_BLOCKED_TRUE_MULTI_WRITER_AMBIGUITY',
      ),
      'route is genuinely ambiguous',
    );
  });
}
