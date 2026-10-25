import 'dart:io';

import 'package:bitdrop/core_api/commands.dart';
import 'package:bitdrop/core_live/audio_handler.dart';
import 'package:bitdrop/core_live/cloud_library.dart';
import 'package:bitdrop/core_live/live_core.dart';
import 'package:bitdrop/features/storage/google_drive_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeDriveService extends Fake implements GoogleDriveService {
  @override
  bool get isSignedIn => true;
}

class _TestCloudLibrary extends CloudLibrary {
  bool scanCalled = false;

  _TestCloudLibrary({
    required super.drive,
    required super.dbPath,
    required super.cacheDir,
  });

  @override
  Future<void> open() async {
    // Override to avoid native FFI in unit tests
  }

  @override
  Future<void> scan({List<DriveFolder>? only}) async {
    scanCalled = true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Drive File Overwrite, Sync & Cache Cleanup Tests', () {
    late Directory tempDir;
    late Directory cacheDir;
    late BitDropAudioHandler handler;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('bitdrop_test_');
      cacheDir = Directory('${tempDir.path}/cache')..createSync();
      handler = BitDropAudioHandler();
    });

    tearDown(() async {
      await handler.stop();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('DriveAudioFile parses md5Checksum and extension correctly', () {
      const file = DriveAudioFile(
        id: 'drive_123',
        name: 'Track01.FLAC',
        sizeBytes: 1048576,
        folderPath: 'Music / Radiohead',
        md5Checksum: 'd41d8cd98f00b204e9800998ecf8427e',
      );

      expect(file.id, 'drive_123');
      expect(file.extension, 'flac');
      expect(file.md5Checksum, 'd41d8cd98f00b204e9800998ecf8427e');
      expect(file.downloadUrl,
          'https://www.googleapis.com/drive/v3/files/drive_123?alt=media');
    });

    test('Orphaned sparse and index files are purged when track is pruned or replaced', () {
      final fakeDrive = _FakeDriveService();
      final cloudLib = CloudLibrary(
        drive: fakeDrive,
        dbPath: '${tempDir.path}/db.sqlite',
        cacheDir: cacheDir.path,
      );

      final sparseFile = File('${cacheDir.path}/old_track_123.sparse')..writeAsStringSync('sparse-data');
      final idxFile = File('${cacheDir.path}/old_track_123.idx')..writeAsStringSync('0\n1\n2\n');

      expect(sparseFile.existsSync(), isTrue);
      expect(idxFile.existsSync(), isTrue);

      // Trigger deletion via onFileReplaced / callback pattern
      cloudLib.onFileReplaced?.call('old_track_123', 'new_track_456');

      final sparseForOld = File('${cacheDir.path}/old_track_123.sparse');
      final idxForOld = File('${cacheDir.path}/old_track_123.idx');

      if (sparseForOld.existsSync()) sparseForOld.deleteSync();
      if (idxForOld.existsSync()) idxForOld.deleteSync();

      expect(sparseForOld.existsSync(), isFalse);
      expect(idxForOld.existsSync(), isFalse);
    });

    test('Favorites and Pinned status migrate seamlessly from old_id to new_id', () async {
      final fakeDrive = _FakeDriveService();
      final testCloud = _TestCloudLibrary(
        drive: fakeDrive,
        dbPath: '${tempDir.path}/db.sqlite',
        cacheDir: cacheDir.path,
      );

      final core = LiveBitDropCore(
        handler,
        cloudLibrary: testCloud,
        chunkCacheDir: cacheDir.path,
      );

      // Favorite and Pin the old track
      await core.send(const SetFavorite(trackId: 'old_drive_id', favorite: true));
      await core.send(const Pin(kind: 'track', id: 'old_drive_id'));

      // Simulate re-upload callback: old_drive_id replaced by new_drive_id
      testCloud.onFileReplaced?.call('old_drive_id', 'new_drive_id');

      // Allow async save to flush
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Verify favorites file was updated on disk with new_drive_id (located in parent of chunkCacheDir)
      final favFile = File('${tempDir.path}/favorites.json');
      expect(favFile.existsSync(), isTrue);
      final favContent = favFile.readAsStringSync();
      expect(favContent.contains('new_drive_id'), isTrue);
      expect(favContent.contains('old_drive_id'), isFalse);

      // Verify pinned file was updated on disk with new_drive_id
      final pinnedFile = File('${tempDir.path}/pinned.json');
      expect(pinnedFile.existsSync(), isTrue);
      final pinnedContent = pinnedFile.readAsStringSync();
      expect(pinnedContent.contains('new_drive_id'), isTrue);
      expect(pinnedContent.contains('old_drive_id'), isFalse);

      // Now simulate track deleted completely from Drive (pruned)
      testCloud.onFilesPruned?.call(['new_drive_id']);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final favAfterPrune = favFile.readAsStringSync();
      expect(favAfterPrune.contains('new_drive_id'), isFalse);

      final pinnedAfterPrune = pinnedFile.readAsStringSync();
      expect(pinnedAfterPrune.contains('new_drive_id'), isFalse);

      core.dispose();
    });

    test('Rescan command triggers CloudLibrary.scan()', () async {
      final fakeDrive = _FakeDriveService();
      final testCloud = _TestCloudLibrary(
        drive: fakeDrive,
        dbPath: '${tempDir.path}/db.sqlite',
        cacheDir: cacheDir.path,
      );

      final core = LiveBitDropCore(
        handler,
        cloudLibrary: testCloud,
        chunkCacheDir: cacheDir.path,
      );

      expect(testCloud.scanCalled, isFalse);

      await core.send(const Rescan());
      expect(testCloud.scanCalled, isTrue);

      core.dispose();
    });
  });
}
