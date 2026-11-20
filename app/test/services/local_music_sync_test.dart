import 'dart:io';

import 'package:bitdrop/core_api/settings.dart';
import 'package:bitdrop/core_live/cloud_library.dart';
import 'package:bitdrop/core_live/persistence_codec.dart';
import 'package:bitdrop/features/storage/google_drive_service.dart';
import 'package:bitdrop/services/local_storage_bridge.dart';
import 'package:bitdrop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeLocalStorageBridge extends LocalStorageBridge {
  _FakeLocalStorageBridge({
    required this.initialStatus,
    this.requestResult,
    this.discoveredDirs = const [],
  });

  AudioStoragePermissionStatus initialStatus;
  AudioStoragePermissionStatus? requestResult;
  List<DiscoveredMusicDirectory> discoveredDirs;
  int requestCalls = 0;

  @override
  Future<AudioStoragePermissionStatus> getAudioPermissionStatus() async =>
      initialStatus;

  @override
  Future<AudioStoragePermissionStatus> requestAudioPermission() async {
    requestCalls += 1;
    final next = requestResult ?? initialStatus;
    initialStatus = next;
    return next;
  }

  @override
  Future<List<DiscoveredMusicDirectory>> discoverMusicDirectories() async =>
      discoveredDirs;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  bool rustReady = false;

  setUpAll(() async {
    final candidates = [
      '${Directory.current.path}/rust/target/debug/librust_lib_bitdrop.so',
      '${Directory.current.path}/../../rust/target/debug/librust_lib_bitdrop.so',
    ];
    final soPath = candidates.firstWhere(
      (p) => File(p).existsSync(),
      orElse: () => candidates.first,
    );
    if (File(soPath).existsSync()) {
      try {
        await RustLib.init(externalLibrary: ExternalLibrary.open(soPath));
        rustReady = true;
      } catch (_) {}
    }
  });

  group('autoSyncLocalMusic setting persistence', () {
    test('defaults to true and survives JSON roundtrip + withKey', () {
      const defaults = AppSettings();
      expect(defaults.autoSyncLocalMusic, isTrue);

      final toggled = defaults.withKey('autoSyncLocalMusic', false);
      expect(toggled.autoSyncLocalMusic, isFalse);

      final json = PersistenceCodec.serializeAppSettings(toggled);
      final restored = PersistenceCodec.deserializeAppSettings(json);
      expect(restored.autoSyncLocalMusic, isFalse);
    });
  });

  group('CloudLibrary.syncDeviceMusic', () {
    test('returns permissionDenied without scanning when permission refused',
        () async {
      final tmp = await Directory.systemTemp.createTemp('bitdrop_sync_perm_');
      addTearDown(() async {
        if (tmp.existsSync()) await tmp.delete(recursive: true);
      });

      final bridge = _FakeLocalStorageBridge(
        initialStatus: const AudioStoragePermissionStatus(granted: false),
        requestResult: const AudioStoragePermissionStatus(
          granted: false,
          permanentlyDenied: true,
        ),
      );
      final library = CloudLibrary(
        drive: GoogleDriveService(),
        dbPath: '${tmp.path}/lib.db',
        cacheDir: '${tmp.path}/cache',
        storageBridge: bridge,
      );
      addTearDown(library.dispose);

      final res = await library.syncDeviceMusic(requestPermission: true);
      expect(bridge.requestCalls, equals(1));
      expect(res.permissionDenied, isTrue);
      expect(res.permanentlyDenied, isTrue);
      expect(res.foldersScanned, equals(0));
    });

    test('discovers device folders, scans tracks, and respects removed exclusions',
        () async {
      if (!rustReady) return;
      final tmp = await Directory.systemTemp.createTemp('bitdrop_sync_local_');
      addTearDown(() async {
        if (tmp.existsSync()) await tmp.delete(recursive: true);
      });

      final musicDir = Directory('${tmp.path}/Music')..createSync();
      final downloadDir = Directory('${tmp.path}/Download')..createSync();
      File('${musicDir.path}/01 - Song A.flac')
          .writeAsBytesSync(List<int>.filled(64, 1));
      File('${downloadDir.path}/02 - Song B.mp3')
          .writeAsBytesSync(List<int>.filled(64, 2));

      final bridge = _FakeLocalStorageBridge(
        initialStatus: const AudioStoragePermissionStatus(granted: true),
        discoveredDirs: [
          DiscoveredMusicDirectory(
            path: musicDir.path,
            label: 'Music',
            audioFileCount: 1,
          ),
          DiscoveredMusicDirectory(
            path: downloadDir.path,
            label: 'Download',
            audioFileCount: 1,
          ),
        ],
      );

      final library = CloudLibrary(
        drive: GoogleDriveService(),
        dbPath: '${tmp.path}/lib.db',
        cacheDir: '${tmp.path}/cache',
        storageBridge: bridge,
      );
      addTearDown(library.dispose);

      final first = await library.syncDeviceMusic(requestPermission: false);
      expect(first.ok, isTrue);
      expect(first.foldersScanned, equals(2));
      expect(first.tracksIndexed, equals(2));
      expect(library.currentLocalFolders, hasLength(2));

      // Remove Download folder -> must be excluded from future auto-discovery.
      await library.removeLocalFolder(downloadDir.path);
      expect(library.currentLocalFolders, hasLength(1));
      expect(library.excludedLocalPaths, contains(downloadDir.path));

      final second = await library.syncDeviceMusic(requestPermission: false);
      expect(second.ok, isTrue);
      expect(second.foldersScanned, equals(1));
      expect(second.tracksIndexed, equals(1));
      expect(library.currentLocalFolders, hasLength(1));
    });
  });
}
