import 'package:bitdrop/core_api/bitdrop_core.dart';
import 'package:bitdrop/core_api/enums.dart';
import 'package:bitdrop/core_api/models.dart';
import 'package:bitdrop/core_live/cloud_library.dart';
import 'package:bitdrop/features/sources/sources_screen.dart';
import 'package:bitdrop/features/storage/google_drive_service.dart';
import 'package:bitdrop/l10n/app_localizations.dart';
import 'package:bitdrop/providers/core_providers.dart';
import 'package:bitdrop/src/rust/cloud/db.dart' as rust_db;
import 'package:bitdrop/theme/app_theme.dart';
import 'package:bitdrop/widgets/cards.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';

class _FakeCore extends Fake implements BitDropCore {
  @override
  Stream<List<SourceAccount>> get sources => const Stream.empty();

  @override
  Stream<SyncStatus> get syncStatus =>
      Stream.value(const SyncStatus(phase: SyncPhase.idle));

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

class _MockDriveService extends GoogleDriveService {
  @override
  bool get isSignedIn => false;

  @override
  Stream<GoogleSignInAccount?> get accountStream => Stream.value(null);

  @override
  GoogleSignInAccount? get currentUser => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LocalFolder Model', () {
    test('serializes to and from JSON correctly', () {
      final now = DateTime(2026, 11, 7, 12, 0, 0);
      const folder = LocalFolder(
        path: '/storage/emulated/0/Music',
        label: 'SD Music',
        lastScanned: null,
        trackCount: 42,
      );

      final json = folder.copyWith(lastScanned: now).toJson();
      expect(json['path'], '/storage/emulated/0/Music');
      expect(json['label'], 'SD Music');
      expect(json['lastScanned'], now.toIso8601String());
      expect(json['trackCount'], 42);

      final reconstructed = LocalFolder.fromJson(json);
      expect(reconstructed.path, folder.path);
      expect(reconstructed.label, folder.label);
      expect(reconstructed.lastScanned, now);
      expect(reconstructed.trackCount, 42);
    });
  });

  group('CloudLibrary Track & Codec Mapping', () {
    test('local absolute paths map to Availability.cached', () {
      final row = rust_db.CloudTrackRow(
        fileId: '/home/user/Music/Jazz/TakeFive.flac',
        name: 'TakeFive.flac',
        folderPath: 'Local Music / Jazz',
        title: 'Take Five',
        artist: 'Dave Brubeck',
        album: 'Time Out',
        albumArtist: 'Dave Brubeck Quartet',
        genre: 'Jazz',
        year: 1959,
        trackNumber: 1,
        discNumber: 1,
        durationMs: 324000,
        sampleRate: 96000,
        channels: 2,
        bitsPerSample: 24,
        sizeBytes: BigInt.from(65000000),
        artworkPath: '/home/user/cache/artwork.jpg',
        tagsRead: true,
      );

      final track = CloudLibrary.trackFromRow(row);
      expect(track.availability, Availability.cached);
      expect(track.id, '/home/user/Music/Jazz/TakeFive.flac');
      expect(track.format.codec, Codec.flac);
      expect(track.format.bitDepth, 24);
      expect(track.format.sampleRate, 96000);
    });

    test('cloud file IDs map to Availability.cloudOnly', () {
      final row = rust_db.CloudTrackRow(
        fileId: '1aBcDeFgHiJkLmNoP',
        name: 'Song.flac',
        folderPath: 'Drive Music',
        title: 'Cloud Song',
        artist: 'Cloud Artist',
        album: 'Cloud Album',
        albumArtist: 'Cloud Artist',
        genre: 'Rock',
        year: 2024,
        trackNumber: 1,
        discNumber: 1,
        durationMs: 200000,
        sampleRate: 44100,
        channels: 2,
        bitsPerSample: 16,
        sizeBytes: BigInt.from(30000000),
        artworkPath: '',
        tagsRead: true,
      );

      final track = CloudLibrary.trackFromRow(row);
      expect(track.availability, Availability.cloudOnly);
    });

    test('DSF and DFF audio files map to Codec.dsf', () {
      final row = rust_db.CloudTrackRow(
        fileId: '/storage/DSD/Track01.dsf',
        name: 'Track01.dsf',
        folderPath: 'DSD',
        title: 'DSD Stream',
        artist: 'Artist',
        album: 'DSD Album',
        albumArtist: 'Artist',
        genre: 'Audiophile',
        year: 2023,
        trackNumber: 1,
        discNumber: 1,
        durationMs: 400000,
        sampleRate: 2822400,
        channels: 2,
        bitsPerSample: 1,
        sizeBytes: BigInt.from(150000000),
        artworkPath: '',
        tagsRead: true,
      );

      final track = CloudLibrary.trackFromRow(row);
      expect(track.format.codec, Codec.dsf);
      expect(track.availability, Availability.cached);
      expect(track.format.sampleRate, 2822400);
      expect(track.format.bitDepth, 1);
    });

    test('empty title falls back to filename without extension', () {
      final row = rust_db.CloudTrackRow(
        fileId: '/storage/Music/02_Track_Name.wav',
        name: '02_Track_Name.wav',
        folderPath: 'Music',
        title: '',
        artist: '',
        album: '',
        albumArtist: '',
        genre: '',
        year: 0,
        trackNumber: 0,
        discNumber: 0,
        durationMs: 180000,
        sampleRate: 44100,
        channels: 2,
        bitsPerSample: 16,
        sizeBytes: BigInt.from(20000000),
        artworkPath: '',
        tagsRead: false,
      );

      final track = CloudLibrary.trackFromRow(row);
      expect(track.title, '02_Track_Name');
      expect(track.artist, 'Unknown artist');
      expect(track.albumTitle, 'Unknown album');
    });
  });

  group('SourceCard UI for Local Device', () {
    testWidgets('renders phone_android icon and up to date badge', (tester) async {
      var rescanCalled = false;
      var editFoldersCalled = false;

      final account = SourceAccount(
        id: 'local',
        provider: 'This Device',
        accountLabel: '2 folders indexed',
        trackCount: 154,
        folderCount: 2,
        status: SourceStatus.upToDate,
        lastSync: DateTime.now(),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            body: SourceCard(
              account: account,
              onRescan: () => rescanCalled = true,
              onEditFolders: () => editFoldersCalled = true,
            ),
          ),
        ),
      );

      expect(find.text('This Device'), findsOneWidget);
      expect(find.text('2 folders indexed'), findsOneWidget);
      expect(find.byIcon(Icons.phone_android), findsOneWidget);
      expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
      expect(find.text('154'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);

      await tester.tap(find.text('Rescan'));
      await tester.pump();
      expect(rescanCalled, isTrue);

      await tester.tap(find.text('Edit folders'));
      await tester.pump();
      expect(editFoldersCalled, isTrue);
    });
  });

  group('SourcesScreen with Local & Cloud Sources', () {
    testWidgets('shows This Device card when local source is present',
        (tester) async {
      final fakeCore = _FakeCore();
      final localAccount = SourceAccount(
        id: 'local',
        provider: 'This Device',
        accountLabel: '1 folder indexed',
        trackCount: 45,
        folderCount: 1,
        status: SourceStatus.upToDate,
        lastSync: DateTime.now(),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            coreProvider.overrideWithValue(fakeCore),
            sourcesProvider.overrideWith((ref) => Stream.value([localAccount])),
            driveServiceProvider.overrideWithValue(_MockDriveService()),
          ],
          child: MaterialApp(
            theme: AppTheme.dark(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(
              body: SourcesScreen(),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('This Device'), findsOneWidget);
      expect(find.text('1 folder indexed'), findsOneWidget);
      expect(find.byIcon(Icons.phone_android), findsOneWidget);
      // Since Drive is not connected, it should appear under "Add a source"
      expect(find.text('Add a source'), findsOneWidget);
      expect(find.text('Google Drive'), findsOneWidget);
    });
  });
}
