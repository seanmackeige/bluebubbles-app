import 'package:flutter/material.dart';
import 'package:bluebubbles/services/ui/chat/logical_draft.dart';

/// Deliberately has no Send callback. The persistent confirmed row also keeps
/// a rapid second tap at this position from landing on the Send control.
class LogicalDraftConfirmationBanner extends StatelessWidget {
  const LogicalDraftConfirmationBanner({
    super.key,
    required this.metadataClass,
    required this.previouslyConfirmed,
    required this.busy,
    required this.onConfirm,
  });
  final LogicalDraftMetadataClass? metadataClass;
  final bool previouslyConfirmed;
  final bool busy;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final legacy = metadataClass == LogicalDraftMetadataClass.legacyUnboundDraft;
    final invalid = metadataClass == LogicalDraftMetadataClass.partiallyBoundInvalidDraft;
    if (!legacy && !invalid && !previouslyConfirmed && !busy) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            invalid
                ? 'Draft safety information needs attention'
                : legacy
                ? 'Draft needs confirmation'
                : 'Draft confirmed',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          Text(
            invalid
                ? 'Your draft is preserved. Sending is paused.'
                : legacy
                ? 'Review this draft and conversation. Confirming saves safety information; it sends nothing.'
                : 'Ready for a separate Send tap. Nothing was sent by confirmation.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: legacy && !busy ? onConfirm : null,
              child: Text(
                busy
                    ? 'Checking draft…'
                    : legacy
                    ? 'Review & Confirm'
                    : invalid
                    ? 'Send paused'
                    : 'Confirmed',
              ),
            ),
          ),
        ],
      ),
    );
  }
}
