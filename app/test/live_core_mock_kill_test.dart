import 'dart:io';
import 'package:bitdrop/core_api/commands.dart';
import 'package:bitdrop/core_api/queries.dart';
import 'package:bitdrop/core_live/audio_handler.dart';
import 'package:bitdrop/core_live/live_core.dart';
import 'package:bitdrop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    const soPath = '/home/razib/Desktop/BitDrop/app/rust/target/debug/librust_lib_bitdrop.so';
    if (File(soPath).existsSync()) {
      try {
        await RustLib.init(externalLibrary: ExternalLibrary.open(soPath));
      } catch (_) {}
    }
  });

  group('Phase 6.5 Mock Core Decoupling Verification', () {
    test('Zero references to MockBitDropCore in release code (live_core.dart)', () {
      final liveCoreFile = File('lib/core_live/live_core.dart');
      expect(liveCoreFile.existsSync(), isTrue, reason: 'live_core.dart must exist');

      final content = liveCoreFile.readAsStringSync();
      expect(
        content.contains('MockBitDropCore'),
        isFalse,
        reason: 'LiveBitDropCore must not contain any reference to MockBitDropCore',
      );
      expect(
        content.contains("import '../core_mock/mock_core.dart';"),
        isFalse,
        reason: 'live_core.dart must not import mock_core.dart',
      );
    });

    test('Zero references to MockBitDropCore across entire core_live directory', () {
      final coreLiveDir = Directory('lib/core_live');
      expect(coreLiveDir.existsSync(), isTrue);

      final dartFiles = coreLiveDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'));

      for (final file in dartFiles) {
        final content = file.readAsStringSync();
        expect(
          content.contains('MockBitDropCore'),
          isFalse,
          reason: '${file.path} must not reference MockBitDropCore',
        );
      }
    });

    test('Bundled AutoEQ assets exist and contain valid ParametricEQ filters', () {
      final autoEqDir = Directory('assets/autoeq');
      expect(autoEqDir.existsSync(), isTrue);

      final files = autoEqDir.listSync().whereType<File>().toList();
      expect(files.length, greaterThanOrEqualTo(4));

      for (final f in files) {
        final text = f.readAsStringSync();
        expect(text, contains('Preamp:'));
        expect(text, contains('Filter'));
        expect(text, contains('Fc'));
        expect(text, contains('Gain'));
        expect(text, contains('Q'));
      }
    });
  });

  group('LiveBitDropCore Native Banners, Sources, and Sleep Timer', () {
    late Directory tempDir;
    late Directory cacheDir;
    late BitDropAudioHandler handler;
    late LiveBitDropCore core;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('bitdrop_mock_kill_test_');
      cacheDir = Directory('${tempDir.path}/cache')..createSync(recursive: true);
      handler = BitDropAudioHandler();
      core = LiveBitDropCore(
        handler,
        chunkCacheDir: cacheDir.path,
      );
    });

    tearDown(() {
      core.dispose();
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('Banners stream functions natively and handles DismissBanner', () async {
      // Initially empty
      final initialBanners = await core.banners.first;
      expect(initialBanners, isEmpty);

      // Dismissing a banner does not throw and maintains empty list
      await core.send(const DismissBanner('test-banner-id'));
      final updatedBanners = await core.banners.first;
      expect(updatedBanners, isEmpty);
    });

    test('Sources stream functions natively without cloud or mock core', () async {
      final sources = await core.sources.first;
      expect(sources, isEmpty);
    });

    test('Sleep timer sets and cancels natively without errors', () async {
      // Set 15-minute sleep timer
      await core.send(const SetSleepTimer(15));

      // Cancel sleep timer
      await core.send(const SetSleepTimer(null));
    });

    test('Query methods return empty/null cleanly without mock core fallback', () async {
      final trk = await core.tracks(const TrackQuery(albumId: 'nonexistent-album-id'));
      expect(trk.items, isEmpty);
      expect(trk.total, 0);

      final alb = await core.album('nonexistent-album-id');
      expect(alb, isNull);

      final art = await core.artist('nonexistent-artist-id');
      expect(art, isNull);
    });
  });
}
