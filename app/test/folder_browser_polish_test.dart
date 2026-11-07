import 'package:bitdrop/core_api/bitdrop_core.dart';
import 'package:bitdrop/core_api/commands.dart';
import 'package:bitdrop/core_api/enums.dart';
import 'package:bitdrop/core_api/models.dart';
import 'package:bitdrop/features/folders/folder_browser.dart';
import 'package:bitdrop/l10n/app_localizations.dart';
import 'package:bitdrop/providers/core_providers.dart';
import 'package:bitdrop/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeFolderCore extends Fake implements BitDropCore {
  final List<PlayerCommand> sentCommands = [];
  String? queriedFolderId;
  int folderCalls = 0;

  @override
  Future<FolderListing> folder(String? folderId) async {
    queriedFolderId = folderId;
    folderCalls++;

    if (folderId == 'Internal Storage/Jazz') {
      return const FolderListing(
        folderId: 'Internal Storage/Jazz',
        breadcrumb: [
          FolderEntry(
              id: 'Internal Storage',
              name: 'Internal Storage',
              isDirectory: true),
          FolderEntry(
              id: 'Internal Storage/Jazz', name: 'Jazz', isDirectory: true),
        ],
        entries: [
          FolderEntry(
            id: '/sdcard/Music/Jazz/TakeFive.flac',
            name: 'Take Five.flac',
            isDirectory: false,
            sizeBytes: 30000000,
            track: Track(
              id: '/sdcard/Music/Jazz/TakeFive.flac',
              title: 'Take Five',
              artist: 'Dave Brubeck',
              albumTitle: 'Time Out',
              albumId: 'al-timeout',
              durationMs: 324000,
              format: AudioFormat(
                codec: Codec.flac,
                bitDepth: 24,
                sampleRate: 96000,
                channels: 2,
              ),
              availability: Availability.cached,
              sizeBytes: 30000000,
              artwork: Artwork(seed: 99, dominantColor: 0xFF2A2A2A),
            ),
          ),
        ],
      );
    } else if (folderId == 'Internal Storage') {
      return const FolderListing(
        folderId: 'Internal Storage',
        breadcrumb: [
          FolderEntry(
              id: 'Internal Storage',
              name: 'Internal Storage',
              isDirectory: true),
        ],
        entries: [
          FolderEntry(
            id: 'Internal Storage/Jazz',
            name: 'Jazz',
            isDirectory: true,
            itemCount: 8,
            sizeBytes: 250000000,
          ),
          FolderEntry(
            id: 'Internal Storage/Rock',
            name: 'Rock',
            isDirectory: true,
            itemCount: 15,
            sizeBytes: 450000000,
          ),
        ],
      );
    }

    return const FolderListing(
      folderId: null,
      breadcrumb: [],
      entries: [
        FolderEntry(
          id: 'Google Drive',
          name: 'Google Drive',
          isDirectory: true,
          itemCount: 120,
          sizeBytes: 4500000000,
        ),
        FolderEntry(
          id: 'Internal Storage',
          name: 'Internal Storage',
          isDirectory: true,
          itemCount: 85,
          sizeBytes: 3200000000,
        ),
      ],
    );
  }

  @override
  Future<void> send(PlayerCommand cmd) async {
    sentCommands.add(cmd);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeFolderCore fakeCore;

  setUp(() {
    fakeCore = _FakeFolderCore();
  });

  Widget buildTestApp({String? rootId, List<Override> overrides = const []}) {
    return ProviderScope(
      overrides: [
        coreProvider.overrideWithValue(fakeCore),
        ...overrides,
      ],
      child: MaterialApp(
        theme: AppTheme.dark(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(
          body: FolderBrowser(rootId: rootId),
        ),
      ),
    );
  }

  group('Part 5.5: Folder Browser Polish, Breadcrumbs & Statistics', () {
    testWidgets(
        'Root level displays source filter chips when multiple sources exist',
        (tester) async {
      await tester.pumpWidget(buildTestApp());
      await tester.pumpAndSettle();

      // Filter chips rendered for All, This Device, Google Drive
      expect(find.text('All'), findsOneWidget);
      expect(find.text('This Device'), findsOneWidget);
      expect(find.text('Google Drive'), findsWidgets); // chip + list item
      expect(find.text('Internal Storage'), findsOneWidget);

      // Select 'This Device' filter chip
      await tester.tap(find.text('This Device'));
      await tester.pumpAndSettle();

      // Only Internal Storage should remain in the list, Google Drive row is filtered
      expect(find.text('Internal Storage'), findsOneWidget);
      expect(find.text('Google Drive'), findsOneWidget); // only the chip remains

      // Select 'Google Drive' filter chip
      await tester.tap(find.text('Google Drive').first);
      await tester.pumpAndSettle();

      // Internal Storage is hidden from list
      expect(find.text('Internal Storage'), findsNothing);

      // Re-select 'All'
      await tester.tap(find.text('All'));
      await tester.pumpAndSettle();

      expect(find.text('Internal Storage'), findsOneWidget);
    });

    testWidgets(
        'Deep folder view renders FolderHeader with statistics, Play All and Shuffle actions',
        (tester) async {
      await tester.pumpWidget(buildTestApp(rootId: 'Internal Storage/Jazz'));
      await tester.pumpAndSettle();

      // Verify breadcrumb shows Folders, Internal Storage, and Jazz
      expect(find.text('Folders'), findsOneWidget);
      expect(find.text('Internal Storage'), findsOneWidget); // parent crumb
      expect(find.text('Jazz'), findsNWidgets(2)); // crumb + header title

      // Header statistics
      expect(find.textContaining('1 track'), findsOneWidget);
      expect(find.text('Play All'), findsOneWidget);
      expect(find.text('Shuffle'), findsOneWidget);

      // Tap 'Play All'
      await tester.tap(find.text('Play All'));
      await tester.pumpAndSettle();

      expect(fakeCore.sentCommands, isNotEmpty);
      final playCmd = fakeCore.sentCommands.whereType<PlayContext>().first;
      expect(playCmd.contextId, 'Internal Storage/Jazz');
      expect(playCmd.trackIds, isEmpty);
      expect(playCmd.shuffle, isFalse);

      // Tap 'Shuffle'
      await tester.tap(find.text('Shuffle'));
      await tester.pumpAndSettle();

      final shuffleCmd = fakeCore.sentCommands.whereType<PlayContext>().last;
      expect(shuffleCmd.contextId, 'Internal Storage/Jazz');
      expect(shuffleCmd.shuffle, isTrue);

      // Tap Queue button in header
      final queueBtn = find.widgetWithIcon(IconButton, Icons.queue_music);
      expect(queueBtn, findsWidgets);
      await tester.tap(queueBtn.first);
      await tester.pumpAndSettle();

      final enqueueCmd = fakeCore.sentCommands.whereType<Enqueue>().first;
      expect(enqueueCmd.trackIds, ['/sdcard/Music/Jazz/TakeFive.flac']);
    });

    testWidgets(
        'Breadcrumb navigation: tapping parent crumb navigates up one level, tapping Folders returns to root',
        (tester) async {
      await tester.pumpWidget(buildTestApp(rootId: 'Internal Storage/Jazz'));
      await tester.pumpAndSettle();

      // Tap 'Internal Storage' crumb
      final parentCrumb = find.text('Internal Storage').first;
      await tester.tap(parentCrumb);
      await tester.pumpAndSettle();

      expect(fakeCore.queriedFolderId, 'Internal Storage');
      expect(find.text('Jazz'), findsOneWidget); // subfolder
      expect(find.text('Rock'), findsOneWidget); // subfolder

      // Tap 'Folders' root crumb
      await tester.tap(find.text('Folders'));
      await tester.pumpAndSettle();

      expect(fakeCore.queriedFolderId, isNull);
      expect(find.text('Favourites'), findsOneWidget);
    });

    testWidgets(
        'FolderRow popup menu displays Play all, Shuffle all, and Add to queue',
        (tester) async {
      await tester.pumpWidget(buildTestApp(rootId: 'Internal Storage'));
      await tester.pumpAndSettle();

      // Find options menu on the Jazz row
      final moreButtons = find.widgetWithIcon(PopupMenuButton<String>, Icons.more_vert);
      expect(moreButtons, findsWidgets);

      // Open options menu for the first folder
      await tester.tap(moreButtons.first);
      await tester.pumpAndSettle();

      expect(find.text('Play all'), findsOneWidget);
      expect(find.text('Shuffle all'), findsOneWidget);
      expect(find.text('Add to queue'), findsOneWidget);
      expect(find.text('Pin for offline'), findsOneWidget);

      // Tap 'Shuffle all'
      await tester.tap(find.text('Shuffle all'));
      await tester.pumpAndSettle();

      final shuffleCmd = fakeCore.sentCommands.whereType<PlayContext>().first;
      expect(shuffleCmd.contextId, 'Internal Storage/Jazz');
      expect(shuffleCmd.shuffle, isTrue);
    });

    testWidgets(
        'libraryRevisionProvider invalidates folderProvider and automatically refreshes folder view',
        (tester) async {
      late WidgetRef capturedRef;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            coreProvider.overrideWithValue(fakeCore),
          ],
          child: MaterialApp(
            theme: AppTheme.dark(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            home: Consumer(
              builder: (context, ref, _) {
                capturedRef = ref;
                return const Scaffold(
                  body: FolderBrowser(rootId: 'Internal Storage'),
                );
              },
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();
      expect(fakeCore.folderCalls, 1);

      // Simulate a background rescan completing which bumps libraryRevisionProvider
      capturedRef.read(libraryRevisionProvider.notifier).state++;
      await tester.pumpAndSettle();

      // folderProvider must have automatically refetched
      expect(fakeCore.folderCalls, 2);
    });
  });
}
