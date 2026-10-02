String logicalRouteOperatorReason(String reason, {String? authorityState}) {
  switch (reason) {
    case 'CURRENT_GENERATION_EXECUTION_UNCORROBORATED':
      return 'latest writer has not been confirmed';
    case 'CURRENT_WRITER_ROUTE_EXECUTION_UNCORROBORATED':
      return 'current writer route has not been confirmed';
    case 'CURRENT_GENERATION_HAS_NO_CANONICAL_ROUTE':
      return 'no writable route is available';
    case 'NO_SUCCESSFUL_OUTBOUND_EXECUTION_PROVENANCE':
      return 'no confirmed send route is available';
  }
  if (authorityState == 'SEND_BLOCKED_TRUE_MULTI_WRITER_AMBIGUITY') {
    return 'route is genuinely ambiguous';
  }
  if (reason.contains('ACCOUNT') || reason.contains('SENDER') || reason.contains('SELF_ALIAS')) {
    return 'account or sender changed';
  }
  if (reason.contains('PARTICIPANT') || reason.contains('EXPANDED_SET')) {
    return 'participant set changed';
  }
  if (reason.contains('AMBIGUOUS') || reason.contains('DUPLICATE') || reason.contains('ZERO_OR')) {
    return 'route is genuinely ambiguous';
  }
  if (reason.contains('SOURCE_BINDING') || reason.contains('CERTIFIED_SOURCE')) {
    return 'conversation source changed';
  }
  if (reason.contains('GENERATION') ||
      reason.contains('HANDOFF') ||
      reason.contains('CONTINUITY') ||
      reason.contains('STALE')) {
    return 'conversation route changed';
  }
  if (reason.contains('ATTACHMENT')) {
    return 'attachment route is unavailable';
  }
  if (reason.contains('PROVENANCE') || reason.contains('ANCHOR') || reason.contains('HISTORY')) {
    return 'recent route evidence is incomplete';
  }
  if (reason.contains('TRANSPORT')) {
    return 'message relay is unavailable';
  }
  if (reason.contains('SCOPE') || reason.contains('CERTIFICATE')) {
    return 'conversation identity changed';
  }
  return 'route could not be verified';
}
