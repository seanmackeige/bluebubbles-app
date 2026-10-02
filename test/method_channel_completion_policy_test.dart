import 'package:bluebubbles/services/backend/java_dart_interop/method_channel_completion_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MethodChannelCompletionPolicy', () {
    test('alive main engine still requires notification mark-read admission', () {
      expect(
        MethodChannelCompletionPolicy.notificationMarkReadRequiresAdmission(
          headless: false,
          lifecycleAlive: true,
        ),
        isTrue,
      );
      expect(
        MethodChannelCompletionPolicy.notificationMarkReadRequiresAdmission(
          headless: true,
          lifecycleAlive: false,
        ),
        isTrue,
      );
    });

    test('propagates literal success', () async {
      expect(await MethodChannelCompletionPolicy.propagate(() async => true), isTrue);
    });

    test('failure injection preserves the retry signal', () async {
      var calls = 0;

      final result = await MethodChannelCompletionPolicy.propagate(() async {
        calls += 1;
        return false;
      });

      expect(result, isFalse);
      expect(calls, 1);
    });

    test('failure injection preserves handler errors', () async {
      final failure = StateError('injected notification action failure');

      await expectLater(
        MethodChannelCompletionPolicy.propagate(() => Future<bool>.error(failure)),
        throwsA(same(failure)),
      );
    });

    test('synchronous handler failure becomes a failed future', () async {
      final failure = StateError('injected synchronous failure');

      await expectLater(MethodChannelCompletionPolicy.propagate(() => throw failure), throwsA(same(failure)));
    });
  });
}
