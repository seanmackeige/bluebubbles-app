import 'package:bluebubbles/services/ui/chat/logical_draft_intent_guard.dart';
import 'package:bluebubbles/env.dart';
import 'package:bluebubbles/services/backend/actions/send_message_actions.dart';
import 'package:bluebubbles/services/isolates/global_isolate.dart';
import 'package:get_it/get_it.dart';

/// Interface layer for outgoing HTTP sends.
///
/// Routes each call through [GlobalIsolate] when on the main thread so that
/// in-flight sends survive the app being backgrounded.  When already running
/// inside the isolate, calls the action directly.
class SendMessageInterface {
  /// Sends a text message and returns the decoded server response body.
  static Future<Map<String, dynamic>> sendTextMessage({
    required String chatGuid,
    required String tempGuid,
    required String message,
    String? method,
    String? effectId,
    String? subject,
    String? selectedMessageGuid,
    int? partIndex,
    bool? ddScan,
    LogicalDraftIntentGuard? logicalIntentGuard,
    String? expectedProviderContextFingerprint,
    String? expectedCertificateRevision,
    String? expectedProviderAccountSnapshotSha256,
    String? expectedProviderFactContractRevision,
    bool allowTransientRetry = true,
  }) async {
    final data = {
      'chatGuid': chatGuid,
      'tempGuid': tempGuid,
      'message': message,
      'method': method,
      'effectId': effectId,
      'subject': subject,
      'selectedMessageGuid': selectedMessageGuid,
      'partIndex': partIndex,
      'ddScan': ddScan,
      'expectedProviderContextFingerprint': expectedProviderContextFingerprint,
      'expectedCertificateRevision': expectedCertificateRevision,
      'expectedProviderAccountSnapshotSha256': expectedProviderAccountSnapshotSha256,
      'expectedProviderFactContractRevision': expectedProviderFactContractRevision,
      'allowTransientRetry': allowTransientRetry,
    };
    // Composer intent and final POST must share one synchronous owner turn.
    // IO remains asynchronous; ordinary/background requests retain the isolate.
    if (logicalIntentGuard != null) {
      return await SendMessageActions.sendTextMessage(data, intentGuard: logicalIntentGuard);
    }
    if (isIsolate) {
      return await SendMessageActions.sendTextMessage(data);
    }
    return await GetIt.I<GlobalIsolate>().send<Map<String, dynamic>>(IsolateRequestType.sendTextMessage, input: data);
  }

  /// Sends a tapback and returns the decoded server response body.
  static Future<Map<String, dynamic>> sendTapback({
    required String chatGuid,
    required String selectedMessageText,
    required String selectedMessageGuid,
    required String reaction,
    int? partIndex,
    LogicalDraftIntentGuard? logicalIntentGuard,
    String? expectedProviderContextFingerprint,
    String? expectedCertificateRevision,
    String? expectedProviderAccountSnapshotSha256,
    String? expectedProviderFactContractRevision,
    bool allowTransientRetry = true,
  }) async {
    final data = {
      'chatGuid': chatGuid,
      'selectedMessageText': selectedMessageText,
      'selectedMessageGuid': selectedMessageGuid,
      'reaction': reaction,
      'partIndex': partIndex,
      'expectedProviderContextFingerprint': expectedProviderContextFingerprint,
      'expectedCertificateRevision': expectedCertificateRevision,
      'expectedProviderAccountSnapshotSha256': expectedProviderAccountSnapshotSha256,
      'expectedProviderFactContractRevision': expectedProviderFactContractRevision,
      'allowTransientRetry': allowTransientRetry,
    };
    // Composer intent and final POST must share one synchronous owner turn.
    // IO remains asynchronous; ordinary/background requests retain the isolate.
    if (logicalIntentGuard != null) {
      return await SendMessageActions.sendTapback(data, intentGuard: logicalIntentGuard);
    }
    if (isIsolate) {
      return await SendMessageActions.sendTapback(data);
    }
    return await GetIt.I<GlobalIsolate>().send<Map<String, dynamic>>(IsolateRequestType.sendTapback, input: data);
  }

  /// Sends a multipart (mention / mixed-content) message and returns the decoded
  /// server response body.
  static Future<Map<String, dynamic>> sendMultipartMessage({
    required String chatGuid,
    required String tempGuid,
    required List<Map<String, dynamic>> parts,
    String? effectId,
    String? subject,
    String? selectedMessageGuid,
    int? partIndex,
    bool? ddScan,
    LogicalDraftIntentGuard? logicalIntentGuard,
    String? expectedProviderContextFingerprint,
    String? expectedCertificateRevision,
    String? expectedProviderAccountSnapshotSha256,
    String? expectedProviderFactContractRevision,
    bool allowTransientRetry = true,
  }) async {
    final data = {
      'chatGuid': chatGuid,
      'tempGuid': tempGuid,
      'parts': parts,
      'effectId': effectId,
      'subject': subject,
      'selectedMessageGuid': selectedMessageGuid,
      'partIndex': partIndex,
      'ddScan': ddScan,
      'expectedProviderContextFingerprint': expectedProviderContextFingerprint,
      'expectedCertificateRevision': expectedCertificateRevision,
      'expectedProviderAccountSnapshotSha256': expectedProviderAccountSnapshotSha256,
      'expectedProviderFactContractRevision': expectedProviderFactContractRevision,
      'allowTransientRetry': allowTransientRetry,
    };
    // Composer intent and final POST must share one synchronous owner turn.
    // IO remains asynchronous; ordinary/background requests retain the isolate.
    if (logicalIntentGuard != null) {
      return await SendMessageActions.sendMultipartMessage(data, intentGuard: logicalIntentGuard);
    }
    if (isIsolate) {
      return await SendMessageActions.sendMultipartMessage(data);
    }
    return await GetIt.I<GlobalIsolate>().send<Map<String, dynamic>>(
      IsolateRequestType.sendMultipartMessage,
      input: data,
    );
  }

  /// Sends an attachment and returns the decoded server response body.
  ///
  /// The isolate reads [filePath] from disk and constructs the multipart form
  /// locally. Upload progress is not reported in v1.
  static Future<Map<String, dynamic>> sendAttachmentMessage({
    required String chatGuid,
    required String tempGuid,
    required String filePath,
    required String fileName,
    required int fileSize,
    String? method,
    String? effectId,
    String? subject,
    String? selectedMessageGuid,
    int? partIndex,
    bool? isAudioMessage,
    LogicalDraftIntentGuard? logicalIntentGuard,
    void Function(int, int)? onLocalProgress,
    String? expectedProviderContextFingerprint,
    String? expectedCertificateRevision,
    String? expectedProviderAccountSnapshotSha256,
    String? expectedProviderFactContractRevision,
    bool allowTransientRetry = true,
  }) async {
    final data = {
      'chatGuid': chatGuid,
      'tempGuid': tempGuid,
      'filePath': filePath,
      'fileName': fileName,
      'fileSize': fileSize,
      'method': method,
      'effectId': effectId,
      'subject': subject,
      'selectedMessageGuid': selectedMessageGuid,
      'partIndex': partIndex,
      'isAudioMessage': isAudioMessage ?? false,
      'expectedProviderContextFingerprint': expectedProviderContextFingerprint,
      'expectedCertificateRevision': expectedCertificateRevision,
      'expectedProviderAccountSnapshotSha256': expectedProviderAccountSnapshotSha256,
      'expectedProviderFactContractRevision': expectedProviderFactContractRevision,
      'allowTransientRetry': allowTransientRetry,
    };
    // Composer intent and final POST must share one synchronous owner turn.
    // IO remains asynchronous; ordinary/background requests retain the isolate.
    if (logicalIntentGuard != null) {
      return await SendMessageActions.sendAttachmentMessage(
        data,
        intentGuard: logicalIntentGuard,
        onLocalProgress: onLocalProgress,
      );
    }
    if (isIsolate) {
      return await SendMessageActions.sendAttachmentMessage(data);
    }
    return await GetIt.I<GlobalIsolate>().send<Map<String, dynamic>>(
      IsolateRequestType.sendAttachmentMessage,
      input: data,
    );
  }
}
