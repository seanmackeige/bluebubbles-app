import 'dart:typed_data';

import 'package:bluebubbles/database/models.dart';
import 'package:path/path.dart';

String gallerySaveNameForAndroid(
  PlatformFile file, {
  required bool isAutoDownload,
}) {
  final originalName = file.name.trim();
  if (!isAutoDownload) return originalName;

  final originalExtension = extension(originalName).toLowerCase();
  final isGif = originalExtension == '.gif';
  if (!isGif) return originalName;

  final baseName = basenameWithoutExtension(originalName).trim();
  final lowerBaseName = baseName.toLowerCase();
  if (originalExtension == '.gif' &&
      lowerBaseName != 'tmp' &&
      lowerBaseName != 'temp') {
    return originalName;
  }

  final safeBaseName = _sanitizeNamePart(baseName.isEmpty ? 'gif' : baseName);
  final suffix = _gallerySaveSuffix(file);
  return '${safeBaseName}_$suffix.gif';
}

String _gallerySaveSuffix(PlatformFile file) {
  final source = file.path != null
      ? basename(dirname(file.path!))
      : _bytesFingerprint(file.bytes, file.size);
  final suffix = _sanitizeNamePart(source);
  return suffix.isEmpty ? 'file_${file.size}' : suffix;
}

String _bytesFingerprint(Uint8List? bytes, int size) {
  if (bytes == null || bytes.isEmpty) return 'size_$size';

  var hash = 0x811c9dc5;
  for (final byte in bytes) {
    hash ^= byte;
    hash = (hash * 0x01000193) & 0xffffffff;
  }

  return '${size}_${hash.toRadixString(16).padLeft(8, '0')}';
}

String _sanitizeNamePart(String value) =>
    value.trim().replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
