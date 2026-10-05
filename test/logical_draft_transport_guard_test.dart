import 'dart:io';
import 'package:get_it/get_it.dart';
import 'package:bluebubbles/services/backend/settings/settings_service.dart';
import 'package:bluebubbles/database/models.dart' show Settings, PlatformFile;
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:bluebubbles/services/ui/chat/logical_draft_intent_guard.dart';
import 'package:bluebubbles/services/network/api/base_api.dart';
import 'package:bluebubbles/services/network/api/message_api.dart';
import 'package:dio/dio.dart';

class FakeAdapter implements HttpClientAdapter {
  int requests = 0;
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? stream, Future<void>? cancel) async {
    requests++;
    return ResponseBody.fromString(
      '{"data":{}}',
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class FakeApi implements BaseApi {
  final adapter = FakeAdapter();
  @override
  late final dio = Dio(BaseOptions(sendTimeout: const Duration(seconds: 1), receiveTimeout: const Duration(seconds: 1)))
    ..httpClientAdapter = adapter;
  @override
  String get origin => 'https://example.invalid';
  @override
  String get apiRoot => '$origin/api/v1';
  @override
  Map<String, String> get headers => {};
  @override
  Map<String, dynamic> buildQueryParams([Map<String, dynamic> params = const {}]) => Map.of(params);
  @override
  Future<Response> returnSuccessOrError(Response r) async => r;
  @override
  Future<Response> runApiGuarded(
    Future<Response> Function() fn, {
    bool checkOrigin = true,
    bool retryTransientMutation = true,
  }) => fn();
}

void main() {
  setUp(() {
    GetIt.I.registerSingleton<SettingsService>(SettingsService()..settings = Settings());
  });
  tearDown(() async {
    await GetIt.I.reset();
  });

  for (final reason in [
    'CONTENT_CHANGED',
    'ATTACHMENT_INTENT_CHANGED',
    'DRAFT_IDENTITY_CHANGED',
    'OWNER_CHANGED',
    'GENERATION_CHANGED_EXTERNAL',
    'DRAFT_CONSUMED',
    'DRAFT_DISAPPEARED',
    'AUTHORITY_CHANGED',
    'CERTIFICATE_CHANGED',
  ]) {
    test('$reason during provider preparation yields zero API requests and retains intent', () async {
      String? change;
      final api = FakeApi();
      final gate = Completer<void>();
      final guard = LogicalDraftIntentGuard(
        validateCurrent: () => change,
        composerIsCurrent: () => change == null,
        record: (_, __) {},
      );
      guard.check();
      final pending = MessageApi(api).sendText(
        'sanitized-chat',
        'temp',
        'sanitized content',
        validateBeforeTransport: () => gate.future,
        validateIntentBeforeTransport: guard.validateBeforeTransport,
        onTransportInvocation: guard.requestStarted,
        allowTransientRetry: false,
      );
      final rejection = expectLater(pending, throwsA(isA<LogicalDraftIntentException>()));
      change = reason;
      gate.complete();
      await rejection;
      expect(api.adapter.requests, 0);
      expect(guard.providerRequestStarted, false);
      expect(guard.blockedReason, reason);
    });
  }
  test('permission diagnostic cannot open an async pre-request gap', () async {
    String? changed;
    final api = FakeApi();
    final guard = LogicalDraftIntentGuard(
      validateCurrent: () => changed,
      composerIsCurrent: () => changed == null,
      record: (result, started) {
        expect(result, 'HTTP_API_INVOKED');
        expect(started, true);
        scheduleMicrotask(() => changed = 'CONTENT_CHANGED');
      },
    );
    await MessageApi(api).sendText(
      'c',
      't',
      'safe',
      validateIntentBeforeTransport: guard.validateBeforeTransport,
      onTransportInvocation: guard.requestStarted,
      allowTransientRetry: false,
    );
    expect(api.adapter.requests, 1);
    expect(guard.composerStillCurrent, false); // new draft is preserved after committed request
  });
  test('unchanged publication and cursor/read events do not invalidate draft', () async {
    final api = FakeApi();
    final guard = LogicalDraftIntentGuard(
      validateCurrent: () => null,
      composerIsCurrent: () => true,
      record: (_, __) {},
    );
    for (var i = 0; i < 1000; i++) {
      guard.check();
    }
    await MessageApi(api).sendText(
      'c',
      't',
      'safe',
      validateIntentBeforeTransport: guard.validateBeforeTransport,
      onTransportInvocation: guard.requestStarted,
      allowTransientRetry: false,
    );
    expect(api.adapter.requests, 1);
  });
  test('old authority is checked only after preparation can rearm it', () {
    var current = false;
    final guard = LogicalDraftIntentGuard(
      validateCurrent: () => null,
      composerIsCurrent: () => true,
      record: (_, __) {},
      validateAuthority: () => current ? null : 'AUTHORITY_CHANGED',
    );
    guard.check();
    expect(guard.validateBeforeTransport, throwsA(isA<LogicalDraftIntentException>()));
    current = true;
    guard.validateBeforeTransport();
  });
  test('owner disposal before request blocks without invocation', () async {
    final api = FakeApi();
    final guard = LogicalDraftIntentGuard(
      validateCurrent: () => null,
      composerIsCurrent: () => true,
      record: (_, __) {},
    );
    guard.close();
    await expectLater(
      MessageApi(api).sendText(
        'c',
        't',
        'safe',
        validateIntentBeforeTransport: guard.validateBeforeTransport,
        onTransportInvocation: guard.requestStarted,
        allowTransientRetry: false,
      ),
      throwsA(isA<LogicalDraftIntentException>()),
    );
    expect(api.adapter.requests, 0);
  });
  test('committed frozen batch proceeds while preserving subsequent composer edit', () async {
    var changed = false;
    String? authority;
    final api = FakeApi();
    final guard = LogicalDraftIntentGuard(
      validateCurrent: () => changed ? 'CONTENT_CHANGED' : null,
      composerIsCurrent: () => !changed,
      validateAuthority: () => authority,
      record: (_, __) {},
    );
    Future<Response> part(String id) => MessageApi(api).sendText(
      'c',
      id,
      'safe',
      validateIntentBeforeTransport: guard.validateBeforeTransport,
      onTransportInvocation: guard.requestStarted,
      allowTransientRetry: false,
    );
    await part('one');
    changed = true;
    await part('two');
    expect(api.adapter.requests, 2);
    expect(guard.composerStillCurrent, false);
    authority = 'AUTHORITY_CHANGED';
    await expectLater(part('three'), throwsA(isA<LogicalDraftIntentException>()));
    expect(api.adapter.requests, 2);
  });
  test('blocked tap does not poison a fresh explicit operation', () async {
    final api = FakeApi();
    for (final changed in [true, false]) {
      final guard = LogicalDraftIntentGuard(
        validateCurrent: () => changed ? 'CONTENT_CHANGED' : null,
        composerIsCurrent: () => !changed,
        record: (_, __) {},
      );
      final operation = MessageApi(api).sendText(
        'c',
        't',
        'safe',
        validateIntentBeforeTransport: guard.validateBeforeTransport,
        onTransportInvocation: guard.requestStarted,
        allowTransientRetry: false,
      );
      if (changed) {
        await expectLater(operation, throwsA(isA<LogicalDraftIntentException>()));
      } else {
        await operation;
      }
    }
    expect(api.adapter.requests, 1);
  });
  for (final kind in ['multipart', 'attachment']) {
    test('$kind final fence follows all asynchronous preparation', () async {
      final api = FakeApi();
      final staged = Completer<void>();
      final release = Completer<void>();
      String? changed;
      final guard = LogicalDraftIntentGuard(
        validateCurrent: () => changed,
        composerIsCurrent: () => changed == null,
        record: (_, __) {},
      );
      final directory = await Directory.systemTemp.createTemp('logical-intent-test-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/fixture.dat');
      await file.writeAsBytes(List<int>.filled(128, 42));
      Future<void> prepare() {
        staged.complete();
        return release.future;
      }

      final future = kind == 'multipart'
          ? MessageApi(api).sendMultipart(
              'c',
              't',
              [],
              validateBeforeTransport: prepare,
              validateIntentBeforeTransport: guard.validateBeforeTransport,
              onTransportInvocation: guard.requestStarted,
              allowTransientRetry: false,
            )
          : MessageApi(api).sendAttachment(
              'c',
              't',
              PlatformFile(name: 'fixture.dat', size: 128, path: file.path),
              method: 'apple-script',
              validateBeforeTransport: prepare,
              validateIntentBeforeTransport: guard.validateBeforeTransport,
              onTransportInvocation: guard.requestStarted,
              allowTransientRetry: false,
            );
      final rejected = expectLater(future, throwsA(isA<LogicalDraftIntentException>()));
      await staged.future;
      changed = 'ATTACHMENT_INTENT_CHANGED';
      release.complete();
      await rejected;
      expect(api.adapter.requests, 0);
      expect(guard.providerRequestStarted, false);
    });
  }
}
