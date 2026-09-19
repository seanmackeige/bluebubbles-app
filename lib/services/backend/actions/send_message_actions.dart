import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/isolates/global_isolate.dart';
import 'package:bluebubbles/services/services.dart';

/// Isolate-dispatchable actions for sending messages via HTTP.
///
/// Each method accepts `Map<String, dynamic>` (as required by [IsolateAction])
/// and returns the decoded server response body so the main isolate can
/// hydrate a [Message] via `Message.fromMap(result['data'])`.
///
class SendMessageActions {
  static void _validateProviderContext(Map<String, dynamic> map) {
    final expected = map['expectedProviderContextFingerprint'] as String?;
    if (expected == null) return;
    final current = logicalProviderContextFingerprint(
      origin: HttpSvc.origin,
      authKey: SettingsSvc.settings.guidAuthKey.value,
      isMinBigSur: SettingsSvc.serverDetails.isMinBigSur,
      isMinVentura: SettingsSvc.serverDetails.isMinVentura,
      isMinSonoma: SettingsSvc.serverDetails.isMinSonoma,
      enablePrivateAPI: SettingsSvc.settings.enablePrivateAPI.value,
      privateAPISend: SettingsSvc.settings.privateAPISend.value,
      privateAPIAttachmentSend: SettingsSvc.settings.privateAPIAttachmentSend.value,
    );
    if (current != expected) {
      throw StateError('LOGICAL_PROVIDER_CONTEXT_CHANGED_BEFORE_TRANSPORT');
    }
  }

  /// Sends a text message via HTTP.
  static Future<Map<String, dynamic>> sendTextMessage(dynamic data) async {
    final map = data as Map<String, dynamic>;
    _validateProviderContext(map);
    final chatGuid = map['chatGuid'] as String;
    final tempGuid = map['tempGuid'] as String;
    final message = map['message'] as String;
    final method = map['method'] as String?;
    final effectId = map['effectId'] as String?;
    final subject = map['subject'] as String?;
    final selectedMessageGuid = map['selectedMessageGuid'] as String?;
    final partIndex = map['partIndex'] as int?;
    final ddScan = map['ddScan'] as bool?;
    final allowTransientRetry = map['allowTransientRetry'] as bool? ?? true;

    final response = await HttpSvc.message.sendText(
      chatGuid,
      tempGuid,
      message,
      method: method,
      effectId: effectId,
      subject: subject,
      selectedMessageGuid: selectedMessageGuid,
      partIndex: partIndex,
      ddScan: ddScan,
      allowTransientRetry: allowTransientRetry,
    );
    return response.data as Map<String, dynamic>;
  }

  /// Sends a tapback via HTTP.
  static Future<Map<String, dynamic>> sendTapback(dynamic data) async {
    final map = data as Map<String, dynamic>;
    _validateProviderContext(map);
    final chatGuid = map['chatGuid'] as String;
    final selectedMessageText = map['selectedMessageText'] as String;
    final selectedMessageGuid = map['selectedMessageGuid'] as String;
    final reaction = map['reaction'] as String;
    final partIndex = map['partIndex'] as int?;
    final allowTransientRetry = map['allowTransientRetry'] as bool? ?? true;

    final response = await HttpSvc.message.sendTapback(
      chatGuid,
      selectedMessageText,
      selectedMessageGuid,
      reaction,
      partIndex: partIndex,
      allowTransientRetry: allowTransientRetry,
    );
    return response.data as Map<String, dynamic>;
  }

  /// Sends a multipart (mention / mixed-content) message via HTTP.
  static Future<Map<String, dynamic>> sendMultipartMessage(dynamic data) async {
    final map = data as Map<String, dynamic>;
    _validateProviderContext(map);
    final chatGuid = map['chatGuid'] as String;
    final tempGuid = map['tempGuid'] as String;
    final parts = (map['parts'] as List).cast<Map<String, dynamic>>();
    final effectId = map['effectId'] as String?;
    final subject = map['subject'] as String?;
    final selectedMessageGuid = map['selectedMessageGuid'] as String?;
    final partIndex = map['partIndex'] as int?;
    final ddScan = map['ddScan'] as bool?;
    final allowTransientRetry = map['allowTransientRetry'] as bool? ?? true;

    final response = await HttpSvc.message.sendMultipart(
      chatGuid,
      tempGuid,
      parts,
      effectId: effectId,
      subject: subject,
      selectedMessageGuid: selectedMessageGuid,
      partIndex: partIndex,
      ddScan: ddScan,
      allowTransientRetry: allowTransientRetry,
    );
    return response.data as Map<String, dynamic>;
  }

  /// Sends an attachment via HTTP.
  ///
  /// Reads the file from [filePath] inside the isolate and constructs
  /// [FormData] locally, avoiding cross-isolate byte transfer.
  static Future<Map<String, dynamic>> sendAttachmentMessage(dynamic data) async {
    final map = data as Map<String, dynamic>;
    _validateProviderContext(map);
    final chatGuid = map['chatGuid'] as String;
    final tempGuid = map['tempGuid'] as String;
    final filePath = map['filePath'] as String;
    final fileName = map['fileName'] as String;
    final fileSize = map['fileSize'] as int;
    final method = map['method'] as String?;
    final effectId = map['effectId'] as String?;
    final subject = map['subject'] as String?;
    final selectedMessageGuid = map['selectedMessageGuid'] as String?;
    final partIndex = map['partIndex'] as int?;
    final isAudioMessage = map['isAudioMessage'] as bool? ?? false;
    final allowTransientRetry = map['allowTransientRetry'] as bool? ?? true;

    final response = await HttpSvc.message.sendAttachment(
      chatGuid,
      tempGuid,
      PlatformFile(name: fileName, path: filePath, size: fileSize),
      method: method,
      effectId: effectId,
      subject: subject,
      selectedMessageGuid: selectedMessageGuid,
      partIndex: partIndex,
      isAudioMessage: isAudioMessage,
      allowTransientRetry: allowTransientRetry,
      validateBeforeTransport: () => _validateProviderContext(map),
      onSendProgress: (count, total) {
        if (total <= 0) return;
        IsolateEventEmitter.emit(IsolateEvent.attachmentUploadProgress, {
          'chatGuid': chatGuid,
          'messageGuid': tempGuid,
          'progress': count / total,
        });
      },
    );
    return response.data as Map<String, dynamic>;
  }
}
