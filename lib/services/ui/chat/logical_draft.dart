import 'dart:convert';

import 'package:crypto/crypto.dart';

const logicalDraftSchema = 'LOGICAL_DRAFT_V1';
const logicalSendAdmissionSchema = 'LOGICAL_SEND_ADMISSION_V2_TRANSPORT_READINESS';

/// Content-safe stable identity for non-composer logical actions. Raw text is
/// hashed and never persisted in the admission key.
String logicalActionIdentity(String namespace, Iterable<Object?> components) {
  final payload = jsonEncode(<String, dynamic>{
    'schema': logicalSendAdmissionSchema,
    'namespace': namespace,
    'components': components.toList(growable: false),
  });
  return sha256.convert(utf8.encode(payload)).toString();
}

String logicalProviderContextFingerprint({
  required String origin,
  required String authKey,
  required bool isMinBigSur,
  required bool isMinVentura,
  required bool isMinSonoma,
  required bool enablePrivateAPI,
  required bool privateAPISend,
  required bool privateAPIAttachmentSend,
}) {
  return sha256
      .convert(
        utf8.encode(
          jsonEncode(<String, dynamic>{
            'origin': origin,
            'authKeySha256': sha256.convert(utf8.encode(authKey)).toString(),
            'isMinBigSur': isMinBigSur,
            'isMinVentura': isMinVentura,
            'isMinSonoma': isMinSonoma,
            'enablePrivateAPI': enablePrivateAPI,
            'privateAPISend': privateAPISend,
            'privateAPIAttachmentSend': privateAPIAttachmentSend,
          }),
        ),
      )
      .toString();
}

/// A durable attachment selection. Only reconstructible file references are
/// persisted. Clipboard bytes and other ephemeral payloads remain represented
/// as non-restorable intent and are never copied into preferences.
class LogicalAttachmentIntent {
  const LogicalAttachmentIntent({
    required this.intentId,
    required this.name,
    required this.size,
    required this.isRestorable,
    this.path,
    this.mimeType,
  });

  final String intentId;
  final String name;
  final int size;
  final bool isRestorable;
  final String? path;
  final String? mimeType;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'intentId': intentId,
    'name': name,
    'size': size,
    'isRestorable': isRestorable,
    if (path != null) 'path': path,
    if (mimeType != null) 'mimeType': mimeType,
  };

  factory LogicalAttachmentIntent.fromJson(Map<String, dynamic> json) {
    return LogicalAttachmentIntent(
      intentId: json['intentId'] as String,
      name: json['name'] as String,
      size: (json['size'] as num).toInt(),
      isRestorable: json['isRestorable'] as bool,
      path: json['path'] as String?,
      mimeType: json['mimeType'] as String?,
    );
  }
}

/// Exact source provenance for a reply selection. It is never rewritten to a
/// newly selected execution chat.
class LogicalReplyIntent {
  const LogicalReplyIntent({
    required this.messageGuid,
    required this.relationshipTargetGuid,
    required this.sourceChatRowId,
    required this.sourceChatGuid,
    required this.part,
  });

  final String messageGuid;
  final String relationshipTargetGuid;
  final int sourceChatRowId;
  final String sourceChatGuid;
  final int part;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'messageGuid': messageGuid,
    'relationshipTargetGuid': relationshipTargetGuid,
    'sourceChatRowId': sourceChatRowId,
    'sourceChatGuid': sourceChatGuid,
    'part': part,
  };

  factory LogicalReplyIntent.fromJson(Map<String, dynamic> json) {
    return LogicalReplyIntent(
      messageGuid: json['messageGuid'] as String,
      relationshipTargetGuid: json['relationshipTargetGuid'] as String,
      sourceChatRowId: (json['sourceChatRowId'] as num).toInt(),
      sourceChatGuid: json['sourceChatGuid'] as String,
      part: (json['part'] as num).toInt(),
    );
  }
}

/// The human workspace for one certified logical conversation.
///
/// [contentRevision] changes only when user intent changes. Re-arming the
/// draft against current authority preserves that revision, allowing a failed
/// send attempt to refresh authority without duplicating the human action.
class LogicalDraft {
  LogicalDraft({
    required this.logicalId,
    required this.text,
    required this.subject,
    required List<LogicalAttachmentIntent> attachments,
    required this.contentRevision,
    required this.createdAtEpochMilliseconds,
    required this.updatedAtEpochMilliseconds,
    this.reply,
    this.effectId,
    this.observedCertificateRevision,
    this.observedAuthorityRevision,
    this.observedAuthorityEpoch,
    this.compositionCertificateRevision,
    this.compositionAuthorityRevision,
    this.compositionAuthorityEpoch,
  }) : attachments = List<LogicalAttachmentIntent>.unmodifiable(attachments);

  final String logicalId;
  final String text;
  final String subject;
  final List<LogicalAttachmentIntent> attachments;
  final LogicalReplyIntent? reply;
  final String? effectId;
  final int contentRevision;
  final int createdAtEpochMilliseconds;
  final int updatedAtEpochMilliseconds;
  final String? observedCertificateRevision;
  final String? observedAuthorityRevision;
  final int? observedAuthorityEpoch;
  final String? compositionCertificateRevision;
  final String? compositionAuthorityRevision;
  final int? compositionAuthorityEpoch;

  String get actionId {
    final input = utf8.encode(
      '$logicalDraftSchema\u0000$logicalId\u0000$createdAtEpochMilliseconds\u0000'
      '$contentRevision\u0000$contentFingerprint',
    );
    return sha256.convert(input).toString();
  }

  String get contentFingerprint {
    final payload = <String, dynamic>{
      'logicalId': logicalId,
      'text': text,
      'subject': subject,
      'attachments': attachments.map((item) => item.toJson()).toList(growable: false),
      if (reply != null) 'reply': reply!.toJson(),
      if (effectId != null) 'effectId': effectId,
    };
    return sha256.convert(utf8.encode(jsonEncode(payload))).toString();
  }

  bool hasSameUserIntent(LogicalDraft other) => contentFingerprint == other.contentFingerprint;

  LogicalDraft rearm(LogicalAuthorityRevision revision, {required int updatedAtEpochMilliseconds}) {
    return LogicalDraft(
      logicalId: logicalId,
      text: text,
      subject: subject,
      attachments: attachments,
      reply: reply,
      effectId: effectId,
      contentRevision: contentRevision,
      createdAtEpochMilliseconds: createdAtEpochMilliseconds,
      updatedAtEpochMilliseconds: updatedAtEpochMilliseconds,
      observedCertificateRevision: revision.certificateRevision,
      observedAuthorityRevision: revision.authorityRevision,
      observedAuthorityEpoch: revision.epoch,
      compositionCertificateRevision: compositionCertificateRevision,
      compositionAuthorityRevision: compositionAuthorityRevision,
      compositionAuthorityEpoch: compositionAuthorityEpoch,
    );
  }

  LogicalDraft mergeUserIntent({
    required String text,
    required String subject,
    required List<LogicalAttachmentIntent> attachments,
    required LogicalReplyIntent? reply,
    required String? effectId,
    required int updatedAtEpochMilliseconds,
    LogicalAuthorityRevision? observedRevision,
  }) {
    final candidate = LogicalDraft(
      logicalId: logicalId,
      text: text,
      subject: subject,
      attachments: attachments,
      reply: reply,
      effectId: effectId,
      contentRevision: contentRevision,
      createdAtEpochMilliseconds: createdAtEpochMilliseconds,
      updatedAtEpochMilliseconds: updatedAtEpochMilliseconds,
      observedCertificateRevision: observedRevision?.certificateRevision ?? observedCertificateRevision,
      observedAuthorityRevision: observedRevision?.authorityRevision ?? observedAuthorityRevision,
      observedAuthorityEpoch: observedRevision?.epoch ?? observedAuthorityEpoch,
      compositionCertificateRevision: compositionCertificateRevision,
      compositionAuthorityRevision: compositionAuthorityRevision,
      compositionAuthorityEpoch: compositionAuthorityEpoch,
    );
    if (hasSameUserIntent(candidate)) return candidate;
    return LogicalDraft(
      logicalId: candidate.logicalId,
      text: candidate.text,
      subject: candidate.subject,
      attachments: candidate.attachments,
      reply: candidate.reply,
      effectId: candidate.effectId,
      contentRevision: contentRevision + 1,
      createdAtEpochMilliseconds: candidate.createdAtEpochMilliseconds,
      updatedAtEpochMilliseconds: candidate.updatedAtEpochMilliseconds,
      observedCertificateRevision: candidate.observedCertificateRevision,
      observedAuthorityRevision: candidate.observedAuthorityRevision,
      observedAuthorityEpoch: candidate.observedAuthorityEpoch,
      compositionCertificateRevision: candidate.compositionCertificateRevision,
      compositionAuthorityRevision: candidate.compositionAuthorityRevision,
      compositionAuthorityEpoch: candidate.compositionAuthorityEpoch,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'schema': logicalDraftSchema,
    'logicalId': logicalId,
    'text': text,
    'subject': subject,
    'attachments': attachments.map((item) => item.toJson()).toList(growable: false),
    if (reply != null) 'reply': reply!.toJson(),
    if (effectId != null) 'effectId': effectId,
    'contentRevision': contentRevision,
    'createdAtEpochMilliseconds': createdAtEpochMilliseconds,
    'updatedAtEpochMilliseconds': updatedAtEpochMilliseconds,
    if (observedCertificateRevision != null) 'observedCertificateRevision': observedCertificateRevision,
    if (observedAuthorityRevision != null) 'observedAuthorityRevision': observedAuthorityRevision,
    if (observedAuthorityEpoch != null) 'observedAuthorityEpoch': observedAuthorityEpoch,
    if (compositionCertificateRevision != null) 'compositionCertificateRevision': compositionCertificateRevision,
    if (compositionAuthorityRevision != null) 'compositionAuthorityRevision': compositionAuthorityRevision,
    if (compositionAuthorityEpoch != null) 'compositionAuthorityEpoch': compositionAuthorityEpoch,
  };

  factory LogicalDraft.create({
    required String logicalId,
    required int nowEpochMilliseconds,
    LogicalAuthorityRevision? observedRevision,
  }) {
    return LogicalDraft(
      logicalId: logicalId,
      text: '',
      subject: '',
      attachments: const <LogicalAttachmentIntent>[],
      contentRevision: 1,
      createdAtEpochMilliseconds: nowEpochMilliseconds,
      updatedAtEpochMilliseconds: nowEpochMilliseconds,
      observedCertificateRevision: observedRevision?.certificateRevision,
      observedAuthorityRevision: observedRevision?.authorityRevision,
      observedAuthorityEpoch: observedRevision?.epoch,
      compositionCertificateRevision: observedRevision?.certificateRevision,
      compositionAuthorityRevision: observedRevision?.authorityRevision,
      compositionAuthorityEpoch: observedRevision?.epoch,
    );
  }

  factory LogicalDraft.fromJson(Map<String, dynamic> json) {
    if (json['schema'] != logicalDraftSchema) {
      throw const FormatException('Unsupported logical draft schema');
    }
    final rawAttachments = json['attachments'];
    if (rawAttachments != null && (rawAttachments is! List || rawAttachments.any((item) => item is! Map))) {
      throw const FormatException('Malformed logical attachment intent list');
    }
    final rawReply = json['reply'];
    if (rawReply != null && rawReply is! Map) {
      throw const FormatException('Malformed logical reply intent');
    }
    return LogicalDraft(
      logicalId: json['logicalId'] as String,
      text: json['text'] as String? ?? '',
      subject: json['subject'] as String? ?? '',
      attachments: (rawAttachments as List? ?? const <dynamic>[])
          .cast<Map>()
          .map((item) => LogicalAttachmentIntent.fromJson(item.cast<String, dynamic>()))
          .toList(growable: false),
      reply: rawReply is Map ? LogicalReplyIntent.fromJson(rawReply.cast<String, dynamic>()) : null,
      effectId: json['effectId'] as String?,
      contentRevision: (json['contentRevision'] as num).toInt(),
      createdAtEpochMilliseconds: (json['createdAtEpochMilliseconds'] as num).toInt(),
      updatedAtEpochMilliseconds: (json['updatedAtEpochMilliseconds'] as num).toInt(),
      observedCertificateRevision: json['observedCertificateRevision'] as String?,
      observedAuthorityRevision: json['observedAuthorityRevision'] as String?,
      observedAuthorityEpoch: (json['observedAuthorityEpoch'] as num?)?.toInt(),
      compositionCertificateRevision:
          (json['compositionCertificateRevision'] ?? json['observedCertificateRevision']) as String?,
      compositionAuthorityRevision:
          (json['compositionAuthorityRevision'] ?? json['observedAuthorityRevision']) as String?,
      compositionAuthorityEpoch: ((json['compositionAuthorityEpoch'] ?? json['observedAuthorityEpoch']) as num?)
          ?.toInt(),
    );
  }
}

class LogicalAuthorityRevision {
  const LogicalAuthorityRevision({
    required this.certificateRevision,
    required this.authorityRevision,
    required this.epoch,
  });

  final String certificateRevision;
  final String authorityRevision;
  final int epoch;

  bool matchesDraft(LogicalDraft draft) {
    return draft.observedCertificateRevision == certificateRevision &&
        draft.observedAuthorityRevision == authorityRevision &&
        draft.observedAuthorityEpoch == epoch;
  }
}

/// Creates monotonically increasing in-process epochs while retaining content
/// digests as the cross-lifecycle identity. A new process intentionally gets a
/// new epoch, forcing a persisted draft through one fresh re-arm.
class LogicalAuthorityRevisionTracker {
  LogicalAuthorityRevisionTracker({int? seedEpoch}) : _epoch = seedEpoch ?? DateTime.now().microsecondsSinceEpoch;

  int _epoch;
  String? _certificateRevision;
  String? _authorityRevision;
  LogicalAuthorityRevision? _current;

  LogicalAuthorityRevision observe({required String certificateRevision, required String authorityRevision}) {
    if (_current == null || certificateRevision != _certificateRevision || authorityRevision != _authorityRevision) {
      _epoch += 1;
      _certificateRevision = certificateRevision;
      _authorityRevision = authorityRevision;
      _current = LogicalAuthorityRevision(
        certificateRevision: certificateRevision,
        authorityRevision: authorityRevision,
        epoch: _epoch,
      );
    }
    return _current!;
  }

  LogicalAuthorityRevision invalidate(String reason) {
    final certificate = _certificateRevision ?? 'UNOBSERVED_CERTIFICATE';
    final prior = _authorityRevision ?? 'UNOBSERVED_AUTHORITY';
    final invalidated = sha256
        .convert(utf8.encode('INVALIDATED\u0000$prior\u0000$reason\u0000${_epoch + 1}'))
        .toString();
    return observe(certificateRevision: certificate, authorityRevision: invalidated);
  }

  LogicalAuthorityRevision? get current => _current;
}

/// Tracks provider-evidence observations separately from authority content.
/// Beginning a newer observation invalidates an older completed observation
/// immediately, including while the newer provider read is still in flight.
class LogicalEvidenceObservationEpochTracker {
  int _startedEpoch = 0;
  int _completedEpoch = 0;

  int begin() => ++_startedEpoch;

  /// Invalidates both cached evidence and any observation currently in flight.
  /// The next observer receives a later epoch and can complete normally.
  void invalidate() {
    _startedEpoch += 1;
  }

  void complete(int epoch) {
    if (epoch <= 0 || epoch != _startedEpoch) {
      throw StateError('LOGICAL_EVIDENCE_OBSERVATION_COMPLETION_OUT_OF_ORDER');
    }
    _completedEpoch = epoch;
  }

  int get completedEpoch => _completedEpoch;

  bool isCurrent(int epoch) => epoch > 0 && epoch == _startedEpoch && epoch == _completedEpoch;
}

enum LogicalSendAdmissionState {
  sendReady,
  transportUnavailable,
  ambiguousPreviousExecution,
  routeAmbiguous,
  authorityChanged,
  participantSetChanged,
  accountChanged,
  serviceChanged,
  providerEvidenceUnavailable,
  replyTargetInvalid,
  attachmentIntentInvalid,
  duplicateAction,
  targetBindingInvalid,
  unsupported,
}

String logicalSendAdmissionUserMessage(LogicalSendAdmissionState state) {
  switch (state) {
    case LogicalSendAdmissionState.sendReady:
      return 'Ready to send';
    case LogicalSendAdmissionState.transportUnavailable:
      return 'Send is blocked because the required SMS relay is unavailable. Your draft was kept.';
    case LogicalSendAdmissionState.ambiguousPreviousExecution:
      return 'A previous execution has an unknown outcome. It was not retried and your draft was kept.';
    case LogicalSendAdmissionState.replyTargetInvalid:
      return 'The reply target can no longer be verified. Your draft was kept.';
    case LogicalSendAdmissionState.attachmentIntentInvalid:
      return 'An attachment is no longer available. Your draft was kept.';
    case LogicalSendAdmissionState.duplicateAction:
      return 'This send is already being processed.';
    case LogicalSendAdmissionState.providerEvidenceUnavailable:
      return 'Send is paused until the current route can be verified.';
    case LogicalSendAdmissionState.routeAmbiguous:
    case LogicalSendAdmissionState.authorityChanged:
    case LogicalSendAdmissionState.participantSetChanged:
    case LogicalSendAdmissionState.accountChanged:
    case LogicalSendAdmissionState.serviceChanged:
    case LogicalSendAdmissionState.targetBindingInvalid:
    case LogicalSendAdmissionState.unsupported:
      return 'Send is paused while this conversation refreshes. Your draft was kept.';
  }
}

LogicalSendAdmissionState logicalSendAdmissionStateForReason(String reason) {
  if (reason.contains('TRANSPORT_UNAVAILABLE')) return LogicalSendAdmissionState.transportUnavailable;
  if (reason.contains('AMBIGUOUS_PREVIOUS_EXECUTION') || reason.contains('OUTCOME_UNKNOWN')) {
    return LogicalSendAdmissionState.ambiguousPreviousExecution;
  }
  if (reason.contains('PARTICIPANT')) return LogicalSendAdmissionState.participantSetChanged;
  if (reason.contains('ACCOUNT') || reason.contains('SENDER')) return LogicalSendAdmissionState.accountChanged;
  if (reason.contains('SERVICE') || reason.contains('GENERATION')) return LogicalSendAdmissionState.serviceChanged;
  if (reason.contains('AUTHORITY') || reason.contains('CERTIFICATE')) {
    return LogicalSendAdmissionState.authorityChanged;
  }
  if (reason.contains('EVIDENCE_UNAVAILABLE') ||
      reason.contains('TRANSPORT_CONTEXT') ||
      reason.contains('PROVIDER_CONTEXT') ||
      reason.contains('SNAPSHOT_UNSTABLE')) {
    return LogicalSendAdmissionState.providerEvidenceUnavailable;
  }
  if (reason.contains('TARGET_MESSAGE') || reason.contains('REPLY')) {
    return LogicalSendAdmissionState.replyTargetInvalid;
  }
  if (reason.contains('ATTACHMENT')) return LogicalSendAdmissionState.attachmentIntentInvalid;
  if (reason.contains('DUPLICATE')) return LogicalSendAdmissionState.duplicateAction;
  if (reason.contains('BINDING')) return LogicalSendAdmissionState.targetBindingInvalid;
  if (reason.contains('AMBIGUOUS') || reason.contains('CANDIDATE')) {
    return LogicalSendAdmissionState.routeAmbiguous;
  }
  return LogicalSendAdmissionState.unsupported;
}

class LogicalSendAdmissionReceipt {
  const LogicalSendAdmissionReceipt({
    required this.admissionId,
    required this.actionId,
    required this.logicalId,
    required this.draftContentRevision,
    required this.certificateRevision,
    required this.authorityRevision,
    required this.authorityEpoch,
    required this.targetSourceChatRowId,
    required this.targetSourceChatGuid,
    required this.transportTempGuid,
    required this.payloadFingerprint,
    required this.intentFingerprint,
    required this.providerContextFingerprint,
    required this.transportReadinessRevision,
    required this.transportSendDisposition,
    required this.committedAtEpochMilliseconds,
  });

  final String admissionId;
  final String actionId;
  final String logicalId;
  final int draftContentRevision;
  final String certificateRevision;
  final String authorityRevision;
  final int authorityEpoch;
  final int targetSourceChatRowId;
  final String targetSourceChatGuid;
  final String transportTempGuid;
  final String payloadFingerprint;
  final String intentFingerprint;
  final String providerContextFingerprint;
  final String transportReadinessRevision;
  final String transportSendDisposition;
  final int committedAtEpochMilliseconds;

  bool get isValid =>
      admissionId.isNotEmpty &&
      actionId.isNotEmpty &&
      logicalId.isNotEmpty &&
      draftContentRevision >= 0 &&
      certificateRevision.isNotEmpty &&
      authorityRevision.isNotEmpty &&
      authorityEpoch > 0 &&
      targetSourceChatRowId > 0 &&
      targetSourceChatGuid.isNotEmpty &&
      transportTempGuid.isNotEmpty &&
      RegExp(r'^[0-9a-f]{64}$').hasMatch(payloadFingerprint) &&
      RegExp(r'^[0-9a-f]{64}$').hasMatch(intentFingerprint) &&
      RegExp(r'^[0-9a-f]{64}$').hasMatch(providerContextFingerprint) &&
      RegExp(r'^[0-9a-f]{64}$').hasMatch(transportReadinessRevision) &&
      <String>{'ready', 'allowedWithReachabilityUnknown'}.contains(transportSendDisposition) &&
      committedAtEpochMilliseconds > 0;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'schema': logicalSendAdmissionSchema,
    'admissionId': admissionId,
    'actionId': actionId,
    'logicalId': logicalId,
    'draftContentRevision': draftContentRevision,
    'certificateRevision': certificateRevision,
    'authorityRevision': authorityRevision,
    'authorityEpoch': authorityEpoch,
    'targetSourceChatRowId': targetSourceChatRowId,
    'targetSourceChatGuid': targetSourceChatGuid,
    'transportTempGuid': transportTempGuid,
    'payloadFingerprint': payloadFingerprint,
    'intentFingerprint': intentFingerprint,
    'providerContextFingerprint': providerContextFingerprint,
    'transportReadinessRevision': transportReadinessRevision,
    'transportSendDisposition': transportSendDisposition,
    'committedAtEpochMilliseconds': committedAtEpochMilliseconds,
  };

  factory LogicalSendAdmissionReceipt.fromJson(Map<String, dynamic> json) {
    if (json['schema'] != logicalSendAdmissionSchema) {
      throw const FormatException('Unsupported logical admission schema');
    }
    final receipt = LogicalSendAdmissionReceipt(
      admissionId: json['admissionId'] as String,
      actionId: json['actionId'] as String,
      logicalId: json['logicalId'] as String,
      draftContentRevision: (json['draftContentRevision'] as num).toInt(),
      certificateRevision: json['certificateRevision'] as String,
      authorityRevision: json['authorityRevision'] as String,
      authorityEpoch: (json['authorityEpoch'] as num).toInt(),
      targetSourceChatRowId: (json['targetSourceChatRowId'] as num).toInt(),
      targetSourceChatGuid: json['targetSourceChatGuid'] as String,
      transportTempGuid: json['transportTempGuid'] as String,
      payloadFingerprint: json['payloadFingerprint'] as String,
      intentFingerprint: json['intentFingerprint'] as String,
      providerContextFingerprint: json['providerContextFingerprint'] as String,
      transportReadinessRevision: json['transportReadinessRevision'] as String,
      transportSendDisposition: json['transportSendDisposition'] as String,
      committedAtEpochMilliseconds: (json['committedAtEpochMilliseconds'] as num).toInt(),
    );
    if (!receipt.isValid) {
      throw const FormatException('Malformed logical admission receipt');
    }
    return receipt;
  }
}

/// Ordinary upstream sends retain their existing transient retry behavior.
/// A revision-bound logical operation is locally dispatch-once; an uncertain
/// transport result is reconciled as UNKNOWN rather than automatically posted
/// a second time.
bool logicalTransportMayRetry(LogicalSendAdmissionReceipt? receipt) => receipt == null;

/// Provider socket echoes can acknowledge optimistic message creation before
/// an SMS relay returns its terminal result. Only ordinary upstream sends may
/// use that echo to complete the local send future.
bool logicalSocketEchoMayComplete(LogicalSendAdmissionReceipt? receipt) => receipt == null;

enum LogicalOperationState { admitted, dispatchReserved, confirmed, outcomeUnknown }

enum LogicalOperationOrigin { seanEditionLedger, externalOrLegacyUnattributed }

class LogicalAdmissionLedger {
  LogicalAdmissionLedger._(this._entries, {required this.capacity, required this.isCorrupt});

  factory LogicalAdmissionLedger.fromEntries(Iterable<Map<String, dynamic>> entries, {int capacity = 512}) {
    final copied = <Map<String, dynamic>>[];
    var corrupt = false;
    final admissionIds = <String>{};
    final actionIds = <String>{};
    final keys = <String>{};
    final transportTempGuids = <String>{};
    for (final entry in entries) {
      try {
        LogicalSendAdmissionReceipt.fromJson(entry);
        final key = entry['admissionKey'] as String;
        final state = entry['operationState'] as String;
        final actionId = entry['actionId'] as String;
        if (!LogicalOperationState.values.any((candidate) => candidate.name == state) ||
            (key != 'initial:$actionId' && key != 'retry:$actionId') ||
            !admissionIds.add(entry['admissionId'] as String) ||
            !actionIds.add(actionId) ||
            !keys.add(key) ||
            !transportTempGuids.add(entry['transportTempGuid'] as String)) {
          corrupt = true;
          continue;
        }
        copied.add(Map<String, dynamic>.from(entry));
      } catch (_) {
        corrupt = true;
      }
    }
    return LogicalAdmissionLedger._(copied, capacity: capacity, isCorrupt: corrupt);
  }

  final int capacity;
  final bool isCorrupt;
  final List<Map<String, dynamic>> _entries;

  List<Map<String, dynamic>> get entries =>
      _entries.map((entry) => Map<String, dynamic>.from(entry)).toList(growable: false);

  bool containsAny(Iterable<String> admissionKeys) {
    final committed = _entries.map((entry) => entry['admissionKey']).whereType<String>().toSet();
    return admissionKeys.any(committed.contains);
  }

  bool containsTransportTempGuid(String tempGuid) {
    if (tempGuid.isEmpty) return false;
    return _entries.any((entry) => entry['transportTempGuid'] == tempGuid);
  }

  LogicalOperationOrigin originForTransportTempGuid(String tempGuid) => containsTransportTempGuid(tempGuid)
      ? LogicalOperationOrigin.seanEditionLedger
      : LogicalOperationOrigin.externalOrLegacyUnattributed;

  List<String> ambiguousAdmissionIdsForIntent(String logicalId, String intentFingerprint) => _entries
      .where(
        (entry) =>
            entry['logicalId'] == logicalId &&
            entry['intentFingerprint'] == intentFingerprint &&
            entry['operationState'] == LogicalOperationState.outcomeUnknown.name,
      )
      .map((entry) => entry['admissionId'])
      .whereType<String>()
      .toList(growable: false);

  bool hasAmbiguousOutcomeForLogical(String logicalId) => _entries.any(
    (entry) => entry['logicalId'] == logicalId && entry['operationState'] == LogicalOperationState.outcomeUnknown.name,
  );

  bool permitsExplicitNewOperation({
    required String logicalId,
    required String intentFingerprint,
    required String? acknowledgedAmbiguousAdmissionId,
    required String newActionId,
  }) {
    if (newActionId.isEmpty) return false;
    final ambiguous = ambiguousAdmissionIdsForIntent(logicalId, intentFingerprint);
    if (ambiguous.isEmpty) return true;
    if (acknowledgedAmbiguousAdmissionId == null || !ambiguous.contains(acknowledgedAmbiguousAdmissionId)) {
      return false;
    }
    final prior = _entries.singleWhere((entry) => entry['admissionId'] == acknowledgedAmbiguousAdmissionId);
    return prior['actionId'] != newActionId;
  }

  bool commitBatch(List<LogicalSendAdmissionReceipt> receipts, List<String> admissionKeys) {
    final receiptIds = receipts.map((receipt) => receipt.admissionId).toList(growable: false);
    final actionIds = receipts.map((receipt) => receipt.actionId).toList(growable: false);
    final transportTempGuids = receipts.map((receipt) => receipt.transportTempGuid).toList(growable: false);
    final existingIds = _entries.map((entry) => entry['admissionId']).whereType<String>().toSet();
    final existingActionIds = _entries.map((entry) => entry['actionId']).whereType<String>().toSet();
    final existingTransportTempGuids = _entries.map((entry) => entry['transportTempGuid']).whereType<String>().toSet();
    if (isCorrupt ||
        receipts.isEmpty ||
        receipts.length > capacity ||
        _entries.length + receipts.length > capacity ||
        receipts.any((receipt) => !receipt.isValid) ||
        receipts.length != admissionKeys.length ||
        admissionKeys.toSet().length != admissionKeys.length ||
        <int>[
          for (var index = 0; index < receipts.length; index++)
            if (admissionKeys[index] != 'initial:${receipts[index].actionId}' &&
                admissionKeys[index] != 'retry:${receipts[index].actionId}')
              index,
        ].isNotEmpty ||
        receiptIds.toSet().length != receiptIds.length ||
        actionIds.toSet().length != actionIds.length ||
        transportTempGuids.toSet().length != transportTempGuids.length ||
        receiptIds.any(existingIds.contains) ||
        actionIds.any(existingActionIds.contains) ||
        transportTempGuids.any(existingTransportTempGuids.contains) ||
        containsAny(admissionKeys)) {
      return false;
    }
    for (var index = 0; index < receipts.length; index++) {
      _entries.add(<String, dynamic>{
        ...receipts[index].toJson(),
        'admissionKey': admissionKeys[index],
        'operationState': LogicalOperationState.admitted.name,
      });
    }
    return true;
  }

  bool transition(String admissionId, LogicalOperationState from, LogicalOperationState to) {
    if (isCorrupt) return false;
    final legal =
        (from == LogicalOperationState.admitted && to == LogicalOperationState.dispatchReserved) ||
        (from == LogicalOperationState.dispatchReserved &&
            (to == LogicalOperationState.confirmed || to == LogicalOperationState.outcomeUnknown));
    if (!legal) return false;
    final matches = <int>[
      for (var index = 0; index < _entries.length; index++)
        if (_entries[index]['admissionId'] == admissionId) index,
    ];
    if (matches.length != 1 || _entries[matches.single]['operationState'] != from.name) return false;
    _entries[matches.single]['operationState'] = to.name;
    return true;
  }

  bool rollbackAdmittedBatch(Iterable<String> admissionIds) {
    if (isCorrupt) return false;
    final ids = admissionIds.toSet();
    if (ids.isEmpty || ids.length != admissionIds.length) return false;
    final matches = _entries.where((entry) => ids.contains(entry['admissionId'])).toList(growable: false);
    if (matches.length != ids.length ||
        matches.any((entry) => entry['operationState'] != LogicalOperationState.admitted.name)) {
      return false;
    }
    _entries.removeWhere((entry) => ids.contains(entry['admissionId']));
    return true;
  }

  /// Removes a batch only while transport is still provably uncalled. A local
  /// dispatch reservation is custody, not evidence that HTTP began.
  bool rollbackBeforeTransportBatch(Iterable<String> admissionIds) {
    if (isCorrupt) return false;
    final ids = admissionIds.toSet();
    if (ids.isEmpty || ids.length != admissionIds.length) return false;
    final matches = _entries.where((entry) => ids.contains(entry['admissionId'])).toList(growable: false);
    if (matches.length != ids.length ||
        matches.any((entry) {
          final state = entry['operationState'];
          return state != LogicalOperationState.admitted.name && state != LogicalOperationState.dispatchReserved.name;
        })) {
      return false;
    }
    _entries.removeWhere((entry) => ids.contains(entry['admissionId']));
    return true;
  }
}

class LogicalSendAdmissionResult {
  const LogicalSendAdmissionResult._({required this.state, required this.reason, this.receipt, this.rearmedDraft});

  const LogicalSendAdmissionResult.ready(LogicalSendAdmissionReceipt receipt)
    : this._(state: LogicalSendAdmissionState.sendReady, reason: 'SEND_READY', receipt: receipt);

  const LogicalSendAdmissionResult.blocked(LogicalSendAdmissionState state, String reason, {LogicalDraft? rearmedDraft})
    : this._(state: state, reason: reason, rearmedDraft: rearmedDraft);

  final LogicalSendAdmissionState state;
  final String reason;
  final LogicalSendAdmissionReceipt? receipt;
  final LogicalDraft? rearmedDraft;

  bool get isReady => state == LogicalSendAdmissionState.sendReady && receipt != null;
}
