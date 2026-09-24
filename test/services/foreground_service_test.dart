import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:NEk0/services/foreground_service.dart';

void main() {
  late Directory tmpDir;
  late File src;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('nek0_save_test_');
    src = File('${tmpDir.path}/src.bin');
    await src.writeAsBytes([1, 2, 3]);
  });

  tearDown(() async {
    if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
  });

  group('saveToCustomDir collision handling', () {
    test('the first save uses the plain display name', () async {
      final dest = await ForegroundService.saveToCustomDir(
        srcPath: src.path,
        displayName: 'song.mp3',
        dir: tmpDir.path,
      );
      expect(dest, '${tmpDir.path}/song.mp3');
      expect(File(dest!).readAsBytesSync(), [1, 2, 3]);
    });

    test(
      'a second save becomes "name (2).ext", a third "name (3).ext"',
      () async {
        await ForegroundService.saveToCustomDir(
          srcPath: src.path,
          displayName: 'song.mp3',
          dir: tmpDir.path,
        );
        final second = await ForegroundService.saveToCustomDir(
          srcPath: src.path,
          displayName: 'song.mp3',
          dir: tmpDir.path,
        );
        expect(second, '${tmpDir.path}/song (2).mp3');
        final third = await ForegroundService.saveToCustomDir(
          srcPath: src.path,
          displayName: 'song.mp3',
          dir: tmpDir.path,
        );
        expect(third, '${tmpDir.path}/song (3).mp3');
      },
    );

    test('existing "name (2)" variants are skipped too', () async {
      File('${tmpDir.path}/song.mp3').createSync();
      File('${tmpDir.path}/song (2).mp3').createSync();
      final dest = await ForegroundService.saveToCustomDir(
        srcPath: src.path,
        displayName: 'song.mp3',
        dir: tmpDir.path,
      );
      expect(dest, '${tmpDir.path}/song (3).mp3');
    });

    test('a name without an extension keeps the whole stem', () async {
      File('${tmpDir.path}/README').createSync();
      final dest = await ForegroundService.saveToCustomDir(
        srcPath: src.path,
        displayName: 'README',
        dir: tmpDir.path,
      );
      expect(dest, '${tmpDir.path}/README (2)');
    });

    test('a leading dot is not treated as an extension separator', () async {
      File('${tmpDir.path}/.hidden').createSync();
      final dest = await ForegroundService.saveToCustomDir(
        srcPath: src.path,
        displayName: '.hidden',
        dir: tmpDir.path,
      );
      expect(dest, '${tmpDir.path}/.hidden (2)');
    });
  });
}
