import 'dart:io';

import 'package:bitdrop/core_api/enums.dart';
import 'package:bitdrop/core_api/models.dart';
import 'package:bitdrop/core_live/audio_handler.dart';
import 'package:bitdrop/core_live/live_core.dart';
import 'package:bitdrop/services/bitdrop_library_service.dart';
import 'package:flutter_test/flutter_test.dart';

class MockRecordingLibraryService extends BitDropLibraryService {
  final List<Map<String, dynamic>> recordedPlaybacks = [];

  @override
  Future<void> recordPlayback({
    required String fileId,
    required int listenedMs,
    int? sampleRate,
    int? bitDepth,
  }) async {
    recordedPlaybacks.add({
      'fileId': fileId,
      'listenedMs': listenedMs,
      'sampleRate': sampleRate,
      'bitDepth': bitDepth,
    });
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Listening Recap Duration Accumulation Tests (Finding C)', () {
    late Directory tempDir;
    late BitDropAudioHandler handler;
    late MockRecordingLibraryService mockLibrary;
    late LiveBitDropCore liveCore;

    const testTrack = Track(
      id: 'track-recap-1',
      title: 'Comfortably Numb',
      artist: 'Pink Floyd',
      albumTitle: 'The Wall',
      albumId: 'album-wall',
      durationMs: 382000,
      sizeBytes: 10000000,
      availability: Availability.cached,
      artwork: Artwork(seed: 1, dominantColor: 0xFF112233),
      format: AudioFormat(
        codec: Codec.flac,
        bitDepth: 24,
        sampleRate: 96000,
      ),
    );

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('bitdrop_recap_test_');
      handler = BitDropAudioHandler();
      mockLibrary = MockRecordingLibraryService();
      liveCore = LiveBitDropCore(
        handler,
        libraryService: mockLibrary,
        chunkCacheDir: tempDir.path,
      );

      // Seed NowPlaying track
      liveCore.nowPlayingSubjectForTesting.add(
        const NowPlaying(track: testTrack, contextLabel: 'Test Album'),
      );
    });

    tearDown(() {
      liveCore.dispose();
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('Accumulates listening time continuously past 30 seconds without premature 30s clamping', () {
      // Simulate playback ticks progressing from 0 to 45,000 ms (45 seconds) in 60ms increments
      int pos = 0;
      liveCore.testCheckAndRecordPlayback(pos, 382000);

      while (pos < 45000) {
        pos += 60;
        liveCore.testCheckAndRecordPlayback(pos, 382000);
      }

      // At 45 seconds, the accumulated listened time should be 45,000 ms
      expect(liveCore.accumulatedListenedMs, equals(45000));

      // Importantly: nothing should be prematurely flushed/locked at 30 seconds
      expect(mockLibrary.recordedPlaybacks.isEmpty, isTrue);

      // Continue playing to 180,000 ms (3 minutes)
      while (pos < 180000) {
        pos += 60;
        liveCore.testCheckAndRecordPlayback(pos, 382000);
      }

      expect(liveCore.accumulatedListenedMs, equals(180000));
      expect(mockLibrary.recordedPlaybacks.isEmpty, isTrue);

      // Track ends/transitions -> flush playback record
      liveCore.testFlushPlaybackRecord();

      // Verified: Exactly 1 record created with the full 180,000 ms (3.0 mins), not 30,000 ms
      expect(mockLibrary.recordedPlaybacks.length, equals(1));
      expect(mockLibrary.recordedPlaybacks.first['fileId'], equals('track-recap-1'));
      expect(mockLibrary.recordedPlaybacks.first['listenedMs'], equals(180000));
      expect(mockLibrary.recordedPlaybacks.first['sampleRate'], equals(96000));
      expect(mockLibrary.recordedPlaybacks.first['bitDepth'], equals(24));
    });

    test('Forward seek does not inflate accumulated listening time', () {
      // Play from 0 to 10,000 ms (10 seconds)
      int pos = 0;
      liveCore.testCheckAndRecordPlayback(pos, 382000);
      for (int i = 0; i < 100; i++) {
        pos += 60;
        liveCore.testCheckAndRecordPlayback(pos, 382000);
      }
      expect(liveCore.accumulatedListenedMs, equals(6000));

      // User seeks forward from 6,000 ms to 100,000 ms (jump of 94 seconds)
      pos = 100000;
      liveCore.testCheckAndRecordPlayback(pos, 382000);

      // Accumulated time must NOT jump by 94 seconds
      expect(liveCore.accumulatedListenedMs, equals(6000));

      // Play an additional 30 seconds (500 ticks of 60ms = 30,000 ms)
      for (int i = 0; i < 500; i++) {
        pos += 60;
        liveCore.testCheckAndRecordPlayback(pos, 382000);
      }

      // Total listened time: 6,000 + 30,000 = 36,000 ms
      expect(liveCore.accumulatedListenedMs, equals(36000));

      liveCore.testFlushPlaybackRecord();
      expect(mockLibrary.recordedPlaybacks.length, equals(1));
      expect(mockLibrary.recordedPlaybacks.first['listenedMs'], equals(36000));
    });

    test('Short tracks (< 30s) qualify at half duration and record full played duration', () {
      const shortTrack = Track(
        id: 'track-short-2',
        title: 'Interlude',
        artist: 'Pink Floyd',
        albumTitle: 'The Wall',
        albumId: 'album-wall',
        durationMs: 20000, // 20 seconds
        sizeBytes: 1000000,
        availability: Availability.cached,
        artwork: Artwork(seed: 2, dominantColor: 0xFF223344),
        format: AudioFormat(
          codec: Codec.flac,
          bitDepth: 16,
          sampleRate: 44100,
        ),
      );

      liveCore.nowPlayingSubjectForTesting.add(
        const NowPlaying(track: shortTrack, contextLabel: 'Short Album'),
      );

      // Play 15 seconds (15,000 ms)
      int pos = 0;
      liveCore.testCheckAndRecordPlayback(pos, 20000);
      for (int i = 0; i < 250; i++) {
        pos += 60;
        liveCore.testCheckAndRecordPlayback(pos, 20000);
      }
      expect(liveCore.accumulatedListenedMs, equals(15000));

      // Track finishes -> qualifies because 15,000 >= 10,000 (duration / 2)
      liveCore.testFlushPlaybackRecord();

      expect(mockLibrary.recordedPlaybacks.length, equals(1));
      expect(mockLibrary.recordedPlaybacks.first['fileId'], equals('track-short-2'));
      expect(mockLibrary.recordedPlaybacks.first['listenedMs'], equals(15000));
    });

    test('Unqualified skips (< 30s on long track) are not recorded in listening recap', () {
      // Play 10 seconds of a 382s track, then skip
      int pos = 0;
      liveCore.testCheckAndRecordPlayback(pos, 382000);
      for (int i = 0; i < 150; i++) {
        pos += 60;
        liveCore.testCheckAndRecordPlayback(pos, 382000);
      }
      expect(liveCore.accumulatedListenedMs, equals(9000));

      liveCore.testFlushPlaybackRecord();
      expect(mockLibrary.recordedPlaybacks.isEmpty, isTrue);
    });
  });
}
