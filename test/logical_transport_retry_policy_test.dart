import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:bluebubbles/services/network/api/base_api.dart';
import 'package:bluebubbles/services/network/api/message_api.dart';
import 'package:bluebubbles/services/ui/chat/logical_draft.dart';
import 'package:bluebubbles/database/models.dart' show PlatformFile;
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class _RecordingApi implements BaseApi {
  @override
  final Dio dio = Dio(BaseOptions(sendTimeout: const Duration(seconds: 1), receiveTimeout: const Duration(seconds: 1)));

  final List<bool> retryPolicies = <bool>[];

  @override
  String get apiRoot => 'https://example.invalid/api/v1';

  @override
  Map<String, String> get headers => const <String, String>{};

  @override
  String get origin => 'https://example.invalid';

  @override
  Map<String, dynamic> buildQueryParams([Map<String, dynamic> params = const <String, dynamic>{}]) =>
      Map<String, dynamic>.from(params);

  @override
  Future<Response> returnSuccessOrError(Response response) async => response;

  @override
  Future<Response> runApiGuarded(
    Future<Response> Function() operation, {
    bool checkOrigin = true,
    bool retryTransientMutation = true,
  }) async {
    retryPolicies.add(retryTransientMutation);
    return Response<Map<String, dynamic>>(
      requestOptions: RequestOptions(path: '/not-executed'),
      statusCode: 200,
      data: <String, dynamic>{'data': <String, dynamic>{}},
    );
  }
}

class _ExecutingApi extends _RecordingApi {
  @override
  Future<Response> runApiGuarded(
    Future<Response> Function() operation, {
    bool checkOrigin = true,
    bool retryTransientMutation = true,
  }) {
    retryPolicies.add(retryTransientMutation);
    return operation();
  }
}

class _RecordingAdapter implements HttpClientAdapter {
  bool transportStarted = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    transportStarted = true;
    return ResponseBody.fromString(
      '{"data":{}}',
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

LogicalSendAdmissionReceipt _receipt() => const LogicalSendAdmissionReceipt(
  admissionId: 'admission-1',
  actionId: 'action-1',
  logicalId: 'logical-1',
  draftContentRevision: 1,
  certificateRevision: 'certificate-1',
  authorityRevision: 'authority-1',
  authorityEpoch: 1,
  targetSourceChatRowId: 2156,
  targetSourceChatGuid: 'source-guid',
  transportTempGuid: 'temp-1',
  payloadFingerprint: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  intentFingerprint: 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
  providerContextFingerprint: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  transportReadinessRevision: 'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd',
  transportSendDisposition: 'allowedWithReachabilityUnknown',
  committedAtEpochMilliseconds: 1,
);

void main() {
  test('logical receipt disables transport retry while ordinary chat behavior is unchanged', () {
    expect(logicalTransportMayRetry(_receipt()), isFalse);
    expect(logicalTransportMayRetry(null), isTrue);
    expect(logicalSocketEchoMayComplete(_receipt()), isFalse);
    expect(logicalSocketEchoMayComplete(null), isTrue);
  });

  test('all outbound provider mutation classes carry the no-retry policy', () async {
    final service = _RecordingApi();
    final api = MessageApi(service);

    await api.sendText('chat', 'temp-text', 'message', allowTransientRetry: false);
    await api.sendTapback('chat', 'message', 'target', 'love', allowTransientRetry: false);
    await api.sendMultipart('chat', 'temp-multipart', const <Map<String, dynamic>>[
      <String, dynamic>{'text': 'message', 'partIndex': 0},
    ], allowTransientRetry: false);
    await api.sendAttachment(
      'chat',
      'temp-attachment',
      PlatformFile(name: 'attachment.bin', size: 1, path: '/not-opened'),
      allowTransientRetry: false,
    );

    expect(service.retryPolicies, <bool>[false, false, false, false]);
  });

  test('ordinary provider mutations retain the upstream transient retry default', () async {
    final service = _RecordingApi();
    final api = MessageApi(service);

    await api.sendText('chat', 'temp-text', 'message');
    await api.sendTapback('chat', 'message', 'target', 'love');

    expect(service.retryPolicies, <bool>[true, true]);
  });

  test('attachment awaits a fresh admission check after file materialization and before transport', () async {
    final directory = await Directory.systemTemp.createTemp('logical-attachment-gate-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/attachment.bin');
    await file.writeAsBytes(const <int>[1, 2, 3], flush: true);

    final service = _ExecutingApi();
    final adapter = _RecordingAdapter();
    service.dio.httpClientAdapter = adapter;
    final validationReached = Completer<void>();
    final releaseValidation = Completer<void>();
    final sending = MessageApi(service).sendAttachment(
      'chat',
      'temp-attachment',
      PlatformFile(name: 'attachment.bin', size: 3, path: file.path),
      allowTransientRetry: false,
      validateBeforeTransport: () async {
        validationReached.complete();
        await releaseValidation.future;
      },
    );

    await validationReached.future.timeout(const Duration(seconds: 5));
    expect(adapter.transportStarted, isFalse);
    releaseValidation.complete();
    await sending;
    expect(adapter.transportStarted, isTrue);
  });
}
