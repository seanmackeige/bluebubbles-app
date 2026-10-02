import 'dart:async';

import 'package:bluebubbles/services/ui/chat/logical_draft.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('slow attachment staging cannot overwrite a newer attachment-empty edit', () async {
    final transactions = LogicalDraftSaveTransactionQueue();
    final stagingStarted = Completer<void>();
    final releaseStaging = Completer<void>();
    final commits = <String>[];

    final older = transactions.run(() async {
      stagingStarted.complete();
      await releaseStaging.future;
      commits.add('older-with-attachment');
    });
    await stagingStarted.future;
    final newer = transactions.run(() async {
      commits.add('newer-without-attachment');
    });

    await Future<void>.delayed(Duration.zero);
    expect(commits, isEmpty);
    releaseStaging.complete();
    await Future.wait(<Future<void>>[older, newer]);
    expect(commits, <String>['older-with-attachment', 'newer-without-attachment']);
    expect(commits.last, 'newer-without-attachment');
  });

  test('failed draft transaction does not poison subsequent human edits', () async {
    final transactions = LogicalDraftSaveTransactionQueue();
    await expectLater(
      transactions.run<void>(() async => throw StateError('injected staging failure')),
      throwsStateError,
    );
    var committed = false;
    await transactions.run(() async => committed = true);
    expect(committed, isTrue);
  });
}
