import 'dart:convert';

import 'package:bluebubbles/services/ui/chat/new_group_conversation.dart';
import 'package:bluebubbles/services/ui/chat/new_group_provider_contract.dart';
import 'package:crypto/crypto.dart';

const createChatV2RequestSchema = 'CREATE_CHAT_V2_REQUEST_V1';
const createChatV2ResponseSchema = 'CREATE_CHAT_V2_RESPONSE_V1';

String _v2Digest(Object? value) => sha256.convert(utf8.encode(jsonEncode(value))).toString();

enum CreateChatV2TerminalState { rejectedBeforeDispatch, executionStarted, succeeded, outcomeAmbiguous }

/// Wire contract for the new helper action. It is deliberately separate from
/// legacy `create-chat`; old helpers cannot accidentally accept this payload.
class CreateChatV2Request {
  CreateChatV2Request({
    required this.operationId,
    required this.accountIdentity,
    required this.senderIdentity,
    required this.service,
    required this.recipientFingerprint,
    required List<String> recipients,
    required this.payloadIdentity,
    required this.providerRevision,
  }) : recipients = List<String>.unmodifiable(recipients);

  factory CreateChatV2Request.fromEnvelope(NewGroupExecutionEnvelope envelope) {
    return CreateChatV2Request(
      operationId: envelope.operationId,
      accountIdentity: envelope.accountIdentity,
      senderIdentity: envelope.senderIdentity,
      service: envelope.requestedService,
      recipientFingerprint: envelope.recipientFingerprint,
      recipients: envelope.normalizedRecipients,
      payloadIdentity: envelope.draftContentFingerprint,
      providerRevision: envelope.providerRevision,
    );
  }

  final String operationId;
  final String accountIdentity;
  final String senderIdentity;
  final NewGroupRequestedService service;
  final String recipientFingerprint;
  final List<String> recipients;
  final String payloadIdentity;
  final String providerRevision;

  bool get structurallyValid {
    if (operationId.isEmpty ||
        accountIdentity.isEmpty ||
        senderIdentity.isEmpty ||
        payloadIdentity.isEmpty ||
        providerRevision.isEmpty ||
        recipients.length < 2 ||
        recipients.toSet().length != recipients.length) {
      return false;
    }
    final sorted = List<String>.of(recipients)..sort();
    if (sorted.any((value) => value.isEmpty)) return false;
    for (var index = 0; index < sorted.length; index += 1) {
      if (sorted[index] != recipients[index]) return false;
    }
    return recipientFingerprint == _v2Digest(recipients);
  }

  String get bindingFingerprint => _v2Digest(toJson());

  Map<String, dynamic> toJson() => <String, dynamic>{
    'schema': createChatV2RequestSchema,
    'operation_id': operationId,
    'account_identity': accountIdentity,
    'sender_identity': senderIdentity,
    'service': service.name,
    'recipient_fingerprint': recipientFingerprint,
    'recipients': recipients,
    'payload_identity': payloadIdentity,
    'provider_revision': providerRevision,
  };
}

class CreateChatV2Response {
  const CreateChatV2Response({
    required this.acceptedOperationId,
    required this.executionStarted,
    required this.providerAccountIdentity,
    required this.providerSenderIdentity,
    required this.service,
    required this.terminalState,
    required this.reasonCode,
    this.chatIdentity,
    this.messageIdentity,
  });

  final String acceptedOperationId;
  final bool executionStarted;
  final String providerAccountIdentity;
  final String providerSenderIdentity;
  final NewGroupRequestedService service;
  final String? chatIdentity;
  final String? messageIdentity;
  final CreateChatV2TerminalState terminalState;
  final String reasonCode;

  bool exactlyMatches(CreateChatV2Request request) {
    if (acceptedOperationId != request.operationId ||
        providerAccountIdentity != request.accountIdentity ||
        providerSenderIdentity != request.senderIdentity ||
        service != request.service) {
      return false;
    }
    if (terminalState == CreateChatV2TerminalState.rejectedBeforeDispatch) {
      return !executionStarted && chatIdentity == null && messageIdentity == null;
    }
    if (terminalState == CreateChatV2TerminalState.succeeded) {
      return executionStarted &&
          (chatIdentity?.isNotEmpty ?? false) &&
          (messageIdentity?.isNotEmpty ?? false);
    }
    return executionStarted;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'schema': createChatV2ResponseSchema,
    'accepted_operation_id': acceptedOperationId,
    'execution_started': executionStarted,
    'provider_account_identity': providerAccountIdentity,
    'provider_sender_identity': providerSenderIdentity,
    'service': service.name,
    'chat_identity_if_known': chatIdentity,
    'message_identity_if_known': messageIdentity,
    'terminal_state': terminalState.name,
    'reason_code': reasonCode,
  };
}

class CreateChatV2Negotiation {
  CreateChatV2Negotiation({
    required this.serverProtocol,
    required this.helperProtocol,
    required Set<String> capabilities,
    required this.serverEvidenceRevision,
    required this.helperEvidenceRevision,
  }) : capabilities = Set<String>.unmodifiable(capabilities);

  final String serverProtocol;
  final String helperProtocol;
  final Set<String> capabilities;
  final String serverEvidenceRevision;
  final String helperEvidenceRevision;

  bool get isProductionComplete {
    return serverProtocol == NewGroupProviderProtocol.createChatV2 &&
        helperProtocol == NewGroupProviderProtocol.createChatV2 &&
        serverEvidenceRevision.isNotEmpty &&
        helperEvidenceRevision.isNotEmpty &&
        capabilities.containsAll(NewGroupProviderCapabilityToken.requiredForProduction);
  }
}

enum CreateChatV2ReservationState { reserved, dispatchStarted, terminal, outcomeAmbiguous }

class CreateChatV2ReservationRecord {
  const CreateChatV2ReservationRecord({
    required this.operationId,
    required this.bindingFingerprint,
    required this.state,
    required this.dispatchCount,
  });

  final String operationId;
  final String bindingFingerprint;
  final CreateChatV2ReservationState state;
  final int dispatchCount;

  CreateChatV2ReservationRecord copyWith({required CreateChatV2ReservationState state, int? dispatchCount}) {
    return CreateChatV2ReservationRecord(
      operationId: operationId,
      bindingFingerprint: bindingFingerprint,
      state: state,
      dispatchCount: dispatchCount ?? this.dispatchCount,
    );
  }
}

/// Deterministic model of the server's durable unique-operation journal.
///
/// It proves at-most-once admission for one operation ID. It does not claim
/// Apple/provider distributed exactly-once. Once dispatch starts, restart or
/// missing terminal evidence remains ambiguous and is never auto-replayed.
class CreateChatV2ReservationJournal {
  final Map<String, CreateChatV2ReservationRecord> _records = <String, CreateChatV2ReservationRecord>{};

  CreateChatV2ReservationRecord reserve(CreateChatV2Request request) {
    if (!request.structurallyValid) throw StateError('CREATE_CHAT_V2_REQUEST_INVALID');
    final existing = _records[request.operationId];
    if (existing != null) {
      if (existing.bindingFingerprint != request.bindingFingerprint) {
        throw StateError('OPERATION_ID_REBOUND_TO_DIFFERENT_PROVIDER_REQUEST');
      }
      return existing;
    }
    final record = CreateChatV2ReservationRecord(
      operationId: request.operationId,
      bindingFingerprint: request.bindingFingerprint,
      state: CreateChatV2ReservationState.reserved,
      dispatchCount: 0,
    );
    _records[request.operationId] = record;
    return record;
  }

  CreateChatV2ReservationRecord startDispatch(String operationId) {
    final current = _records[operationId];
    if (current == null) throw StateError('OPERATION_NOT_RESERVED');
    if (current.state != CreateChatV2ReservationState.reserved) return current;
    final started = current.copyWith(state: CreateChatV2ReservationState.dispatchStarted, dispatchCount: 1);
    _records[operationId] = started;
    return started;
  }

  CreateChatV2ReservationRecord markTerminal(String operationId) {
    final current = _records[operationId];
    if (current == null || current.state != CreateChatV2ReservationState.dispatchStarted) {
      throw StateError('TERMINAL_WITHOUT_DISPATCH');
    }
    final terminal = current.copyWith(state: CreateChatV2ReservationState.terminal);
    _records[operationId] = terminal;
    return terminal;
  }

  CreateChatV2ReservationRecord recoverAfterRestart(String operationId) {
    final current = _records[operationId];
    if (current == null) throw StateError('OPERATION_NOT_RESERVED');
    if (current.state != CreateChatV2ReservationState.dispatchStarted) return current;
    final ambiguous = current.copyWith(state: CreateChatV2ReservationState.outcomeAmbiguous);
    _records[operationId] = ambiguous;
    return ambiguous;
  }

  CreateChatV2ReservationRecord? recordFor(String operationId) => _records[operationId];
}
