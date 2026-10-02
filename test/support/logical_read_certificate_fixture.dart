import 'dart:convert';

import 'package:bluebubbles/services/ui/chat/logical_conversation_view.dart';

const readFixtureFirstRow = 2027;
const readFixtureSecondRow = 2155;
const readFixturePresentationRow = 2156;
const readFixtureHistoricalDifferentSetRow = 1674;

List<LogicalConversationPhysicalChatBinding> bankedReadFixtureBindings({
  int firstRow = readFixtureFirstRow,
  int secondRow = readFixtureSecondRow,
  int presentationRow = readFixturePresentationRow,
}) {
  const anchor = LogicalConversationViewPolicy.bankedReadTrustAnchor;
  return <LogicalConversationPhysicalChatBinding>[
    LogicalConversationPhysicalChatBinding.fromGuidSha256(
      sourceChatRowId: firstRow,
      sourceChatGuidSha256: anchor.members[0].sourceChatGuidSha256,
    ),
    LogicalConversationPhysicalChatBinding.fromGuidSha256(
      sourceChatRowId: secondRow,
      sourceChatGuidSha256: anchor.members[1].sourceChatGuidSha256,
    ),
    LogicalConversationPhysicalChatBinding.fromGuidSha256(
      sourceChatRowId: presentationRow,
      sourceChatGuidSha256: anchor.presentationSourceChatGuidSha256,
    ),
  ];
}

LogicalConversationReadCertificate bindBankedReadFixture({
  String? persistedCertificateJson,
  Iterable<LogicalConversationPhysicalChatBinding> extraBindings = const <LogicalConversationPhysicalChatBinding>[],
  int firstRow = readFixtureFirstRow,
  int secondRow = readFixtureSecondRow,
  int presentationRow = readFixturePresentationRow,
}) {
  final available = <LogicalConversationPhysicalChatBinding>[
    ...bankedReadFixtureBindings(firstRow: firstRow, secondRow: secondRow, presentationRow: presentationRow),
    ...extraBindings,
  ];
  if (!LogicalConversationViewPolicy.bindRuntimeCertificate(
    physicalChats: available,
    persistedCertificateJson: persistedCertificateJson,
  )) {
    throw StateError('BANKED_READ_FIXTURE_BINDING_FAILED');
  }
  return LogicalConversationViewPolicy.activeCertificate;
}

String encodeLegacyBuild99ReadCertificate(LogicalConversationReadCertificate certificate) {
  final members = certificate.members.toList()
    ..sort((left, right) => left.sourceChatRowId.compareTo(right.sourceChatRowId));
  return jsonEncode(<String, dynamic>{
    'schema': logicalConversationLegacyRuntimeCertificateSchema,
    'certificate': <String, dynamic>{
      'schema': certificate.schema,
      'id': certificate.id,
      'revision': certificate.revision,
      'presentationSourceChatRowId': certificate.presentationSourceChatRowId,
      'members': [
        for (final member in members)
          <String, dynamic>{
            'sourceChatRowId': member.sourceChatRowId,
            'sourceChatGuidHmacSha256': member.sourceChatGuidHmacSha256,
            'sourceChatGuidSha256': member.sourceChatGuidSha256,
            'admissionReceiptCommit': member.admissionReceiptCommit,
            'admissionEvidenceSha256': member.admissionEvidenceSha256,
            'evidence': member.evidence.map((value) => value.name).toList()..sort(),
            'pairwiseComparedSourceRowIds': member.pairwiseComparedSourceRowIds.toList()..sort(),
            'directRelationshipPeerRowIds': member.directRelationshipPeerRowIds.toList()..sort(),
            'minimumStructuredRelationshipCount': member.minimumStructuredRelationshipCount,
            'explanation': member.explanation,
          },
      ],
    },
  });
}
