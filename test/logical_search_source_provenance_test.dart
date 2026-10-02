import 'package:bluebubbles/app/layouts/conversation_list/pages/search/search_source_provenance.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, dynamic> payload(List<Map<String, dynamic>> chats) => <String, dynamic>{
    'guid': 'message-guid',
    'chats': chats,
  };

  test('selected logical source is preserved even when it is not chats.first', () {
    final envelope = NetworkSearchResponseEnvelope(
      requestedSourceGuid: 'physical-b',
      message: payload(<Map<String, dynamic>>[
        <String, dynamic>{'guid': 'physical-a'},
        <String, dynamic>{'guid': 'physical-b'},
      ]),
    );
    expect(exactNetworkSearchSourceChatMap(envelope)?['guid'], 'physical-b');
  });

  test('missing or duplicate requested source fails closed', () {
    final missing = NetworkSearchResponseEnvelope(
      requestedSourceGuid: 'physical-b',
      message: payload(<Map<String, dynamic>>[
        <String, dynamic>{'guid': 'physical-a'},
      ]),
    );
    final duplicate = NetworkSearchResponseEnvelope(
      requestedSourceGuid: 'physical-b',
      message: payload(<Map<String, dynamic>>[
        <String, dynamic>{'guid': 'physical-b'},
        <String, dynamic>{'guid': 'physical-b'},
      ]),
    );
    expect(exactNetworkSearchSourceChatMap(missing), isNull);
    expect(exactNetworkSearchSourceChatMap(duplicate), isNull);
  });

  test('unscoped search admits exactly one embedded chat relation', () {
    final single = NetworkSearchResponseEnvelope(
      requestedSourceGuid: null,
      message: payload(<Map<String, dynamic>>[
        <String, dynamic>{'guid': 'physical-a'},
      ]),
    );
    final ambiguous = NetworkSearchResponseEnvelope(
      requestedSourceGuid: null,
      message: payload(<Map<String, dynamic>>[
        <String, dynamic>{'guid': 'physical-a'},
        <String, dynamic>{'guid': 'physical-b'},
      ]),
    );
    expect(exactNetworkSearchSourceChatMap(single)?['guid'], 'physical-a');
    expect(exactNetworkSearchSourceChatMap(ambiguous), isNull);
  });

  test('legacy response envelope retains the query source for every item', () {
    final envelopes = envelopeNetworkSearchResponse(<dynamic>[
      payload(<Map<String, dynamic>>[
        <String, dynamic>{'guid': 'physical-a'},
      ]),
      'malformed',
    ], requestedSourceGuid: 'physical-a');
    expect(envelopes, hasLength(1));
    expect(envelopes.single.requestedSourceGuid, 'physical-a');
  });
}
