import 'package:bluebubbles/helpers/helpers.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart' hide Response;

class ChatCreatorDialogs {
  static Future<void> showGroupChatCreationDialog(BuildContext context) {
    return showBBDialog(
      barrierDismissible: false,
      context: context,
      title: "Group creation unavailable",
      body:
          "Sean Edition cannot safely create a new group because the exact sending account and caller identity cannot be guaranteed. Existing conversations remain available.",
      actions: [BBDialogAction(text: "Close", onPressed: () => Navigator.of(context, rootNavigator: true).pop())],
    );
  }

  static Future<void> showCannotForwardAttachmentDialog(BuildContext context) {
    return showBBDialog(
      context: context,
      title: "Cannot Forward Attachment",
      body: "Attachments cannot be forwarded to a new conversation. Please select an existing contact.",
      actions: [
        BBDialogAction(text: "OK", isDefault: true, onPressed: () => Navigator.of(context, rootNavigator: true).pop()),
      ],
    );
  }

  static Widget buildCreatingChatDialog(BuildContext context, String method) {
    return AlertDialog(
      backgroundColor: context.theme.colorScheme.surfaceContainerHighest,
      title: Text("Creating a new $method chat...", style: context.theme.textTheme.titleLarge),
      content: SizedBox(
        height: 70,
        child: Center(
          child: CircularProgressIndicator(
            backgroundColor: context.theme.colorScheme.surfaceContainerHighest,
            valueColor: AlwaysStoppedAnimation<Color>(context.theme.colorScheme.primary),
          ),
        ),
      ),
    );
  }

  static Widget buildCreateChatErrorDialog(BuildContext context, Object error) {
    return AlertDialog(
      backgroundColor: context.theme.colorScheme.surfaceContainerHighest,
      title: Text("Failed to create chat!", style: context.theme.textTheme.titleLarge),
      content: Text(
        error is Response
            ? "Reason: (${error.data["error"]["type"]}) -> ${error.data["error"]["message"]}"
            : error.toString(),
        style: context.theme.textTheme.bodyLarge,
      ),
      actions: [
        TextButton(
          child: Text(
            "OK",
            style: context.theme.textTheme.bodyLarge!.copyWith(color: Get.context!.theme.colorScheme.primary),
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}
