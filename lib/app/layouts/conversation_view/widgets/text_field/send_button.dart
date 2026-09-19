import 'dart:async';

import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

class SendButton extends StatefulWidget {
  const SendButton({super.key, required this.onLongPress, required this.sendMessage});

  final Function() onLongPress;
  final Future<void> Function() sendMessage;

  @override
  SendButtonState createState() => SendButtonState();
}

class SendButtonState extends State<SendButton> with SingleTickerProviderStateMixin, ThemeHelpers {
  bool _sendInFlight = false;
  late final controller = AnimationController(
    vsync: this,
    duration: Duration(seconds: SettingsSvc.settings.sendDelay.value),
    animationBehavior: AnimationBehavior.preserve,
  );

  // Colors cached here and refreshed in didChangeDependencies so they update
  // when an inherited Theme changes (e.g. per-chat adaptive theme loading).
  late Color _iosBaseColor;
  late Color _materialBaseColor;
  late Color _errorColor;
  late Color _iosOnPrimary;
  late Color _materialIconColor;
  late Color _onError;

  Color get baseColor => iOS ? _iosBaseColor : _materialBaseColor;

  Future<void> _sendOnce() async {
    if (_sendInFlight) return;
    _sendInFlight = true;
    try {
      await widget.sendMessage();
    } finally {
      _sendInFlight = false;
    }
  }

  @override
  void initState() {
    super.initState();
    controller.addListener(() {
      if (controller.isCompleted) {
        controller.reset();
        unawaited(_sendOnce());
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _iosBaseColor = context.theme.colorScheme.primary;
    _materialBaseColor = context.theme.colorScheme.surfaceContainerHighest;
    _errorColor = context.theme.colorScheme.error;
    _iosOnPrimary = context.theme.colorScheme.onPrimary;
    _materialIconColor = ThemeSvc.isAnyMaterialYouSelected
        ? context.theme.colorScheme.onPrimary
        : context.theme.colorScheme.secondary;
    _onError = context.theme.colorScheme.onError;
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onSecondaryTap: () {
        if (controller.isAnimating) {
          controller.reset();
        } else {
          widget.onLongPress.call();
        }
      },
      child: TextButton(
        style: TextButton.styleFrom(
          backgroundColor: iOS ? _iosBaseColor : null,
          shape: const CircleBorder(),
          padding: const EdgeInsets.all(0),
          maximumSize: const Size(32, 32),
          minimumSize: const Size(32, 32),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: AnimatedBuilder(
          animation: controller,
          builder: (context, widget) {
            return _SendButtonIcon(
              animationValue: controller.value,
              baseColor: baseColor,
              errorColor: _errorColor,
              iosOnPrimary: _iosOnPrimary,
              materialSecondary: _materialIconColor,
              onError: _onError,
            );
          },
        ),
        onPressed: () {
          if (controller.isAnimating) {
            controller.reset();
          } else if (SettingsSvc.settings.sendDelay.value != 0) {
            controller.forward();
          } else {
            HapticFeedback.lightImpact();
            unawaited(_sendOnce());
          }
        },
        onLongPress: () {
          if (controller.isAnimating) {
            controller.reset();
          } else {
            widget.onLongPress.call();
          }
        },
      ),
    );
  }
}

/// Extracted animated icon to reduce rebuild scope
class _SendButtonIcon extends StatelessWidget {
  const _SendButtonIcon({
    required this.animationValue,
    required this.baseColor,
    required this.errorColor,
    required this.iosOnPrimary,
    required this.materialSecondary,
    required this.onError,
  });

  final double animationValue;
  final Color baseColor;
  final Color errorColor;
  final Color iosOnPrimary;
  final Color materialSecondary;
  final Color onError;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final isIOS = SettingsSvc.settings.skin.value == Skins.iOS;
      final isAnimating = animationValue != 0;

      return Container(
        constraints: const BoxConstraints(minHeight: 32, minWidth: 32),
        decoration: BoxDecoration(
          shape: isIOS ? BoxShape.circle : BoxShape.rectangle,
          borderRadius: isIOS ? null : BorderRadius.circular(10),
          gradient: isIOS || isAnimating
              ? LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [baseColor, baseColor, errorColor, errorColor],
                  stops: [0.0, 1 - animationValue, 1 - animationValue, 1.0],
                )
              : null,
        ),
        alignment: Alignment.center,
        child: Icon(
          animationValue == 0
              ? (isIOS ? CupertinoIcons.arrow_up : Icons.send_outlined)
              : (isIOS ? CupertinoIcons.xmark : Icons.close),
          color: animationValue == 0 ? (isIOS ? iosOnPrimary : materialSecondary) : onError,
          size: isIOS || isAnimating ? 20 : 28,
        ),
      );
    });
  }
}
