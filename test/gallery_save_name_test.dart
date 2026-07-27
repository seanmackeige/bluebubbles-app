import 'dart:typed_data';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/utils/gallery_save_name.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('gallerySaveNameForAndroid', () {
    test('keeps normal GIF filenames unchanged', () {
      final file = PlatformFile(
        name: 'reaction.gif',
        path:
            '/data/user/0/com.bluebubbles.messaging/app_flutter/attachments/abc123/reaction.gif',
        size: 42,
      );

      expect(
        gallerySaveNameForAndroid(
          file,
          isAutoDownload: true,
        ),
        'reaction.gif',
      );
    });

    test('renames auto-downloaded temp GIFs with the attachment directory', () {
      final file = PlatformFile(
        name: 'tmp.gif',
        path:
            '/data/user/0/com.bluebubbles.messaging/app_flutter/attachments/ABC-123/tmp.gif',
        size: 42,
      );

      expect(
        gallerySaveNameForAndroid(
          file,
          isAutoDownload: true,
        ),
        'tmp_ABC-123.gif',
      );
    });

    test('does not change manual saves', () {
      final file = PlatformFile(
        name: 'tmp.gif',
        path:
            '/data/user/0/com.bluebubbles.messaging/app_flutter/attachments/abc123/tmp.gif',
        size: 42,
      );

      expect(
        gallerySaveNameForAndroid(
          file,
          isAutoDownload: false,
        ),
        'tmp.gif',
      );
    });

    test('does not rename non-GIF images', () {
      final file = PlatformFile(
        name: 'tmp.jpg',
        path:
            '/data/user/0/com.bluebubbles.messaging/app_flutter/attachments/abc123/tmp.jpg',
        size: 42,
      );

      expect(
        gallerySaveNameForAndroid(
          file,
          isAutoDownload: true,
        ),
        'tmp.jpg',
      );
    });

    test('uses deterministic byte fingerprints when no path exists', () {
      final file = PlatformFile(
        name: 'temp.gif',
        size: 3,
        bytes: Uint8List.fromList([1, 2, 3]),
      );

      final first = gallerySaveNameForAndroid(
        file,
        isAutoDownload: true,
      );
      final second = gallerySaveNameForAndroid(
        file,
        isAutoDownload: true,
      );

      expect(first, second);
      expect(first, startsWith('temp_3_'));
      expect(first, endsWith('.gif'));
    });
  });
}
