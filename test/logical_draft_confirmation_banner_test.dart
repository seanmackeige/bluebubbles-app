import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bluebubbles/services/ui/chat/logical_draft.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/logical_draft_confirmation_banner.dart';

void main() {
  testWidgets('legacy control invokes confirmation only and retains a separate Send control', (tester) async {
    var confirmations = 0;
    var sends = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              LogicalDraftConfirmationBanner(
                metadataClass: LogicalDraftMetadataClass.legacyUnboundDraft,
                previouslyConfirmed: false,
                busy: false,
                onConfirm: () => confirmations++,
              ),
              TextButton(onPressed: () => sends++, child: const Text('Send')),
            ],
          ),
        ),
      ),
    );
    expect(find.text('Draft needs confirmation'), findsOneWidget);
    await tester.tap(find.text('Review & Confirm'));
    await tester.pump();
    expect(confirmations, 1);
    expect(sends, 0);
  });
  for (final state in ['busy', 'confirmed', 'invalid', 'modern']) {
    testWidgets('$state cannot invoke confirmation or make confirmation a send', (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LogicalDraftConfirmationBanner(
              metadataClass: state == 'busy'
                  ? LogicalDraftMetadataClass.legacyUnboundDraft
                  : state == 'invalid'
                  ? LogicalDraftMetadataClass.partiallyBoundInvalidDraft
                  : LogicalDraftMetadataClass.modernBoundDraft,
              previouslyConfirmed: state == 'confirmed',
              busy: state == 'busy',
              onConfirm: () => calls++,
            ),
          ),
        ),
      );
      for (final button in tester.widgetList<TextButton>(find.byType(TextButton))) {
        expect(button.onPressed, isNull);
      }
      expect(calls, 0);
      if (state == 'modern') expect(find.byType(TextButton), findsNothing);
    });
  }
}
