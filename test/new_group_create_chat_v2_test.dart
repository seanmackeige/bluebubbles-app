import 'package:bluebubbles/services/ui/chat/new_group_conversation.dart';
import 'package:bluebubbles/services/ui/chat/new_group_create_chat_v2.dart';
import 'package:bluebubbles/services/ui/chat/new_group_provider_contract.dart';
import 'package:flutter_test/flutter_test.dart';

NewGroupRecipientEvidence _recipient(String id, String handle) {
  return NewGroupRecipientEvidence(
    selectionId: id,
    normalizedHandle: handle,
    isSelf: false,
    iMessageCapability: NewGroupRecipientCapability.available,
    smsMmsCapability: NewGroupRecipientCapability.available,
    resolutionRevision: 'resolution-$id',
    observedAtEpochMilliseconds: 900,
    validUntilEpochMilliseconds: 2000,
  );
}

NewGroupExecutionEnvelope _envelope({
  String operationId = 'operation-v2',
  String account = 'account-a',
  String sender = 'sender-a',
  NewGroupRequestedService service = NewGroupRequestedService.iMessage,
  String text = 'first message',
}) {
  final intent = NewLogicalConversationIntent(
    operationId: operationId,
    recipients: <NewGroupRecipientEvidence>[_recipient('alice', '+15550000001'), _recipient('bob', 'bob@example.test')],
    requestedService: service,
    expectedAccountIdentity: account,
    expectedSenderIdentity: sender,
    draftText: text,
    attachments: const <NewGroupAttachmentIntent>[],
    contentRevision: 1,
    createdAtEpochMilliseconds: 800,
  );
  return NewGroupExecutionEnvelope.fromIntent(intent, 'provider-revision-v2');
}

CreateChatV2Negotiation _negotiation({
  String server = NewGroupProviderProtocol.createChatV2,
  String helper = NewGroupProviderProtocol.createChatV2,
  Set<String> capabilities = NewGroupProviderCapabilityToken.requiredForProduction,
}) {
  return CreateChatV2Negotiation(
    serverProtocol: server,
    helperProtocol: helper,
    capabilities: capabilities,
    serverEvidenceRevision: 'server-evidence',
    helperEvidenceRevision: 'helper-evidence',
  );
}

void main() {
  group('CREATE_CHAT_V2 protocol', () {
    test('complete explicit-bound handshake is accepted', () {
      expect(_negotiation().isProductionComplete, isTrue);
    });

    test('old helper and capability omission fail closed', () {
      expect(_negotiation(helper: NewGroupProviderProtocol.legacyV1).isProductionComplete, isFalse);
      final missingSender = <String>{...NewGroupProviderCapabilityToken.requiredForProduction}
        ..remove(NewGroupProviderCapabilityToken.senderBound);
      expect(_negotiation(capabilities: missingSender).isProductionComplete, isFalse);
    });

    test('request binds operation account sender service recipients and payload', () {
      final request = CreateChatV2Request.fromEnvelope(_envelope());

      expect(request.structurallyValid, isTrue);
      expect(request.toJson(), containsPair('operation_id', 'operation-v2'));
      expect(request.toJson(), containsPair('account_identity', 'account-a'));
      expect(request.toJson(), containsPair('sender_identity', 'sender-a'));
      expect(request.toJson(), containsPair('service', 'iMessage'));
      expect(request.recipients, <String>['+15550000001', 'bob@example.test']);
      expect(request.payloadIdentity, isNotEmpty);
    });

    test('unsorted duplicate or fingerprint-mismatched recipients are invalid', () {
      final valid = CreateChatV2Request.fromEnvelope(_envelope());
      final variants = <CreateChatV2Request>[
        CreateChatV2Request(
          operationId: valid.operationId,
          accountIdentity: valid.accountIdentity,
          senderIdentity: valid.senderIdentity,
          service: valid.service,
          recipientFingerprint: valid.recipientFingerprint,
          recipients: valid.recipients.reversed.toList(),
          payloadIdentity: valid.payloadIdentity,
          providerRevision: valid.providerRevision,
        ),
        CreateChatV2Request(
          operationId: valid.operationId,
          accountIdentity: valid.accountIdentity,
          senderIdentity: valid.senderIdentity,
          service: valid.service,
          recipientFingerprint: valid.recipientFingerprint,
          recipients: <String>[valid.recipients.first, valid.recipients.first],
          payloadIdentity: valid.payloadIdentity,
          providerRevision: valid.providerRevision,
        ),
        CreateChatV2Request(
          operationId: valid.operationId,
          accountIdentity: valid.accountIdentity,
          senderIdentity: valid.senderIdentity,
          service: valid.service,
          recipientFingerprint: 'wrong',
          recipients: valid.recipients,
          payloadIdentity: valid.payloadIdentity,
          providerRevision: valid.providerRevision,
        ),
      ];

      expect(variants.every((value) => !value.structurallyValid), isTrue);
    });

    test('response must echo exact account sender service and operation', () {
      final request = CreateChatV2Request.fromEnvelope(_envelope());
      final response = CreateChatV2Response(
        acceptedOperationId: request.operationId,
        executionStarted: true,
        providerAccountIdentity: request.accountIdentity,
        providerSenderIdentity: request.senderIdentity,
        service: request.service,
        chatIdentity: 'chat-guid',
        messageIdentity: 'message-guid',
        terminalState: CreateChatV2TerminalState.succeeded,
        reasonCode: 'SUCCESS',
      );

      expect(response.exactlyMatches(request), isTrue);
      expect(
        CreateChatV2Response(
          acceptedOperationId: request.operationId,
          executionStarted: true,
          providerAccountIdentity: request.accountIdentity,
          providerSenderIdentity: request.senderIdentity,
          service: request.service,
          terminalState: CreateChatV2TerminalState.succeeded,
          reasonCode: 'SUCCESS_WITHOUT_OBSERVED_IDENTITIES',
        ).exactlyMatches(request),
        isFalse,
      );
      expect(
        CreateChatV2Response(
          acceptedOperationId: request.operationId,
          executionStarted: true,
          providerAccountIdentity: request.accountIdentity,
          providerSenderIdentity: 'other-sender',
          service: request.service,
          terminalState: CreateChatV2TerminalState.executionStarted,
          reasonCode: 'STARTED',
        ).exactlyMatches(request),
        isFalse,
      );
    });

    test('pre-dispatch rejection cannot claim chat or message identity', () {
      final request = CreateChatV2Request.fromEnvelope(_envelope());
      final rejected = CreateChatV2Response(
        acceptedOperationId: request.operationId,
        executionStarted: false,
        providerAccountIdentity: request.accountIdentity,
        providerSenderIdentity: request.senderIdentity,
        service: request.service,
        terminalState: CreateChatV2TerminalState.rejectedBeforeDispatch,
        reasonCode: 'ACCOUNT_UNAVAILABLE',
      );
      final invalid = CreateChatV2Response(
        acceptedOperationId: request.operationId,
        executionStarted: false,
        providerAccountIdentity: request.accountIdentity,
        providerSenderIdentity: request.senderIdentity,
        service: request.service,
        chatIdentity: 'invented-chat',
        terminalState: CreateChatV2TerminalState.rejectedBeforeDispatch,
        reasonCode: 'ACCOUNT_UNAVAILABLE',
      );

      expect(rejected.exactlyMatches(request), isTrue);
      expect(invalid.exactlyMatches(request), isFalse);
    });
  });

  group('durable provider operation identity', () {
    test('one operation ID can cross the physical dispatch boundary once', () {
      final journal = CreateChatV2ReservationJournal();
      final request = CreateChatV2Request.fromEnvelope(_envelope());

      expect(journal.reserve(request).state, CreateChatV2ReservationState.reserved);
      expect(journal.startDispatch(request.operationId).dispatchCount, 1);
      expect(journal.startDispatch(request.operationId).dispatchCount, 1);
      expect(journal.markTerminal(request.operationId).state, CreateChatV2ReservationState.terminal);
      expect(journal.reserve(request).dispatchCount, 1);
      expect(journal.startDispatch(request.operationId).dispatchCount, 1);
    });

    test('same operation ID cannot be rebound to another sender or service', () {
      final journal = CreateChatV2ReservationJournal();
      journal.reserve(CreateChatV2Request.fromEnvelope(_envelope()));

      expect(() => journal.reserve(CreateChatV2Request.fromEnvelope(_envelope(sender: 'sender-b'))), throwsStateError);
      expect(
        () => journal.reserve(CreateChatV2Request.fromEnvelope(_envelope(service: NewGroupRequestedService.smsMms))),
        throwsStateError,
      );
    });

    test('restart after dispatch begins becomes ambiguous and never reopens dispatch', () {
      final journal = CreateChatV2ReservationJournal();
      final request = CreateChatV2Request.fromEnvelope(_envelope());
      journal.reserve(request);
      journal.startDispatch(request.operationId);

      final recovered = journal.recoverAfterRestart(request.operationId);

      expect(recovered.state, CreateChatV2ReservationState.outcomeAmbiguous);
      expect(recovered.dispatchCount, 1);
      expect(journal.reserve(request).state, CreateChatV2ReservationState.outcomeAmbiguous);
      expect(journal.startDispatch(request.operationId).dispatchCount, 1);
    });

    test('property: repeated reserve and dispatch never exceeds one dispatch', () {
      final journal = CreateChatV2ReservationJournal();
      for (var index = 0; index < 64; index += 1) {
        final request = CreateChatV2Request.fromEnvelope(
          _envelope(operationId: 'operation-$index', text: 'message-$index'),
        );
        for (var repeat = 0; repeat < 8; repeat += 1) {
          journal.reserve(request);
          journal.startDispatch(request.operationId);
        }
        expect(journal.recordFor(request.operationId)?.dispatchCount, 1);
      }
    });
  });
}
