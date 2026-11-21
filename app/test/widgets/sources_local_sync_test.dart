import 'package:bitdrop/core_api/bitdrop_core.dart';
import 'package:bitdrop/core_api/models.dart';
import 'package:bitdrop/core_live/cloud_library.dart';
import 'package:bitdrop/features/sources/sources_screen.dart';
import 'package:bitdrop/features/storage/google_drive_service.dart';
import 'package:bitdrop/l10n/app_localizations.dart';
import 'package:bitdrop/providers/core_providers.dart';
import 'package:bitdrop/services/local_storage_bridge.dart';
import 'package:bitdrop/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:rxdart/rxdart.dart';

class _FakeCore extends Fake implements BitDropCore {
  @override
  Stream<StorageState> get storage => Stream.value(
        const StorageState(
          cacheBytes: 0,
          cacheLimitBytes: 1024 * 1024 * 100,
          pinnedBytes: 0,
          freeBytes: 1024 * 1024 * 1000,
          totalBytes: 1024 * 1024 * 2000,
          artworkBytes: 0,
        ),
      );
}

class _FakeDriveService extends GoogleDriveService {
  @override
  bool get isSignedIn => false;

  @override
  Stream<GoogleSignInAccount?> get accountStream => Stream.value(null);

  @override
  GoogleSignInAccount? get currentUser => null;
}

class _FakeBridge extends Fake implements LocalStorageBridge {
  _FakeBridge({
    required this.permission,
    this.discovered = const [],
  });

  AudioStoragePermissionStatus permission;
  List<DiscoveredMusicDirectory> discovered;
  bool openAppSettingsCalled = false;

  @override
  Future<AudioStoragePermissionStatus> getAudioPermissionStatus() async =>
      permission;

  @override
  Future<bool> openAppSettings() async {
    openAppSettingsCalled = true;
    return true;
  }

  @override
  Future<List<DiscoveredMusicDirectory>> discoverMusicDirectories() async =>
      discovered;
}

class _FakeCloudLibrary extends Fake implements CloudLibrary {
  _FakeCloudLibrary({
    required this.bridge,
    List<LocalFolder> initialFolders = const [],
  }) : _foldersSubject = BehaviorSubject<List<LocalFolder>>.seeded(initialFolders);

  final _FakeBridge bridge;
  final BehaviorSubject<List<LocalFolder>> _foldersSubject;
  final _localSyncingSubject = BehaviorSubject<bool>.seeded(false);
  final _statusSubject =
      BehaviorSubject<SyncStatus>.seeded(SyncStatus.idle);

  bool syncDeviceMusicCalled = false;
  final List<String> addedFolders = [];
  final List<String> removedFolders = [];

  @override
  LocalStorageBridge get storageBridge => bridge;

  @override
  Stream<bool> get localSyncing => _localSyncingSubject.stream;

  @override
  Stream<SyncStatus> get status => _statusSubject.stream;

  @override
  Stream<List<LocalFolder>> get localFolders => _foldersSubject.stream;

  @override
  List<LocalFolder> get currentLocalFolders => _foldersSubject.value;

  @override
  Future<LocalSyncResult> syncDeviceMusic({
    bool requestPermission = true,
    bool includeDiscovered = true,
  }) async {
    syncDeviceMusicCalled = true;
    return const LocalSyncResult(tracksIndexed: 12, foldersScanned: 2);
  }

  @override
  Future<int> addLocalFolder(String directoryPath, {String? label}) async {
    addedFolders.add(directoryPath);
    final next = [
      ..._foldersSubject.value,
      LocalFolder(path: directoryPath, label: label ?? 'Folder', trackCount: 4),
    ];
    _foldersSubject.add(next);
    return 4;
  }

  @override
  Future<void> removeLocalFolder(String directoryPath) async {
    removedFolders.add(directoryPath);
    final next =
        _foldersSubject.value.where((f) => f.path != directoryPath).toList();
    _foldersSubject.add(next);
  }

  Future<void> disposeSubjects() async {
    await _foldersSubject.close();
    await _localSyncingSubject.close();
    await _statusSubject.close();
  }
}

void main() {
  Widget wrapWithProviders({
    required Widget child,
    required _FakeBridge bridge,
    required _FakeCloudLibrary cloudLibrary,
    List<SourceAccount> sources = const [],
  }) =>
      ProviderScope(
        overrides: [
          coreProvider.overrideWithValue(_FakeCore()),
          driveServiceProvider.overrideWithValue(_FakeDriveService()),
          localStorageBridgeProvider.overrideWithValue(bridge),
          cloudLibraryProvider.overrideWithValue(cloudLibrary),
          sourcesProvider.overrideWith((ref) => Stream.value(sources)),
        ],
        child: MaterialApp(
          theme: AppTheme.dark(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: child),
        ),
      );

  group('SourcesScreen & LocalFoldersSheet device music sync', () {
    testWidgets('shows Sync Device Music card when ready and triggers sync',
        (tester) async {
      final bridge = _FakeBridge(
        permission: const AudioStoragePermissionStatus(granted: true),
      );
      final cloud = _FakeCloudLibrary(bridge: bridge);
      addTearDown(cloud.disposeSubjects);

      await tester.pumpWidget(
        wrapWithProviders(
          child: const SourcesScreen(),
          bridge: bridge,
          cloudLibrary: cloud,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Ready'), findsOneWidget);
      expect(find.text('Sync Device Music'), findsOneWidget);

      await tester.tap(find.text('Sync Device Music'));
      await tester.pumpAndSettle();

      expect(cloud.syncDeviceMusicCalled, isTrue);
      expect(find.text('Synced 12 tracks across 2 folders.'), findsOneWidget);
    });

    testWidgets(
        'shows Open App Settings when permission is permanently denied',
        (tester) async {
      final bridge = _FakeBridge(
        permission: const AudioStoragePermissionStatus(
          granted: false,
          permanentlyDenied: true,
        ),
      );
      final cloud = _FakeCloudLibrary(bridge: bridge);
      addTearDown(cloud.disposeSubjects);

      await tester.pumpWidget(
        wrapWithProviders(
          child: const SourcesScreen(),
          bridge: bridge,
          cloudLibrary: cloud,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Settings required'), findsOneWidget);
      expect(find.text('Open App Settings'), findsOneWidget);

      await tester.tap(find.text('Open App Settings'));
      await tester.pump();

      expect(bridge.openAppSettingsCalled, isTrue);
    });

    testWidgets(
        'LocalFoldersSheet renders discovered internal & SD folders with switches',
        (tester) async {
      final bridge = _FakeBridge(
        permission: const AudioStoragePermissionStatus(granted: true),
        discovered: const [
          DiscoveredMusicDirectory(
            path: '/storage/emulated/0/Music',
            label: 'Music',
            isRemovable: false,
            audioFileCount: 18,
          ),
          DiscoveredMusicDirectory(
            path: '/storage/SDCARD-1/Music',
            label: 'SD Card · Music',
            isRemovable: true,
            audioFileCount: 9,
          ),
        ],
      );
      final cloud = _FakeCloudLibrary(
        bridge: bridge,
        initialFolders: const [
          LocalFolder(
            path: '/storage/emulated/0/Music',
            label: 'Music',
            trackCount: 18,
          ),
        ],
      );
      addTearDown(cloud.disposeSubjects);

      await tester.pumpWidget(
        wrapWithProviders(
          child: const LocalFoldersSheet(),
          bridge: bridge,
          cloudLibrary: cloud,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Discovered on device'), findsOneWidget);
      expect(find.text('Music'), findsOneWidget);
      expect(find.text('SD Card · Music'), findsOneWidget);
      expect(find.text('Internal'), findsOneWidget);
      expect(find.text('SD Card'), findsOneWidget);

      final switches = find.byType(Switch);
      expect(switches, findsNWidgets(2));

      // First folder (/storage/emulated/0/Music) is already enabled -> toggle OFF
      await tester.tap(switches.at(0));
      await tester.pumpAndSettle();
      expect(cloud.removedFolders, ['/storage/emulated/0/Music']);

      // Second folder (/storage/SDCARD-1/Music) is disabled -> toggle ON
      await tester.tap(switches.at(1));
      await tester.pumpAndSettle();
      expect(cloud.addedFolders, ['/storage/SDCARD-1/Music']);
    });

    testWidgets(
        'SourceCard Rescan on local account triggers syncDeviceMusic',
        (tester) async {
      final bridge = _FakeBridge(
        permission: const AudioStoragePermissionStatus(granted: true),
      );
      final cloud = _FakeCloudLibrary(bridge: bridge);
      addTearDown(cloud.disposeSubjects);

      final localAccount = SourceAccount(
        id: 'local',
        provider: 'This Device',
        accountLabel: '1 folder indexed',
        trackCount: 18,
        folderCount: 1,
        status: SourceStatus.upToDate,
        lastSync: DateTime.now(),
      );

      await tester.pumpWidget(
        wrapWithProviders(
          child: const SourcesScreen(),
          bridge: bridge,
          cloudLibrary: cloud,
          sources: [localAccount],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Rescan'));
      await tester.pumpAndSettle();

      expect(cloud.syncDeviceMusicCalled, isTrue);
    });
  });
}
