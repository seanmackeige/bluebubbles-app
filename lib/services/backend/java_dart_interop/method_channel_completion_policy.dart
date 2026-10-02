/// Preserves the Dart handler's exact completion signal across the method-
/// channel boundary. A `false` result requests a native worker retry, while an
/// error remains an error; neither may be collapsed into success.
abstract final class MethodChannelCompletionPolicy {
  /// Notification mark-read is an explicit user mutation. A live main engine
  /// must admit and apply it just like a headless engine; lifecycle state is
  /// never grounds for reporting a false success.
  static bool notificationMarkReadRequiresAdmission({required bool headless, required bool lifecycleAlive}) {
    return true;
  }

  static Future<bool> propagate(Future<bool> Function() handler) async {
    return handler();
  }
}
