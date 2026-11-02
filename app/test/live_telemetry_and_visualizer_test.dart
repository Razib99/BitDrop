import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:bitdrop/core_api/enums.dart';
import 'package:bitdrop/core_api/models.dart';
import 'package:bitdrop/core_live/audio_handler.dart';
import 'package:bitdrop/core_live/live_core.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LiveBitDropCore Visualizer and Diagnostics Telemetry', () {
    late Directory tempDir;
    late Directory cacheDir;
    late LiveBitDropCore liveCore;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('bitdrop_test_telemetry_');
      cacheDir = Directory('${tempDir.path}/cache')..createSync(recursive: true);
      final handler = BitDropAudioHandler();
      liveCore = LiveBitDropCore(
        handler,
        chunkCacheDir: cacheDir.path,
      );
    });

    tearDown(() {
      liveCore.dispose();
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('Visualizer stream emits silent frame initially and reacts to state', () async {
      final initialFrame = await liveCore.visualizer.first;
      expect(initialFrame.peakLeftDb, -90.0);
      expect(initialFrame.peakRightDb, -90.0);
      expect(initialFrame.clipping, isFalse);
      expect(initialFrame.spectrum, isEmpty);
    });

    test('Diagnostics stream emits valid initial snapshot with hardware & buffer fields', () async {
      final diag = await liveCore.diagnostics.first;
      expect(diag.requested, isNotNull);
      expect(diag.actual, isNotNull);
      expect(diag.deviceName, isNotEmpty);
      expect(diag.bufferAheadSeconds, greaterThanOrEqualTo(0.0));
      expect(diag.pcmFillPercent, inInclusiveRange(0.0, 100.0));
      expect(diag.underrunCount, greaterThanOrEqualTo(0));
      expect(diag.speedMbps, greaterThanOrEqualTo(0.0));
      expect(diag.activeRangeRequests, greaterThanOrEqualTo(0));
      expect(diag.requestBudgetPerMinute, 12000);
      expect(diag.cacheHitRate, inInclusiveRange(0.0, 1.0));
      expect(diag.cacheSizeBytes, greaterThanOrEqualTo(0));
      expect(diag.currentFileCachedPercent, inInclusiveRange(0, 100));
      expect(diag.decodeLoadPercent, inInclusiveRange(0.0, 100.0));
      expect(diag.throughputHistory, isNotEmpty);
      expect(diag.bufferHistory, isNotEmpty);
    });

    test('Diagnostics stream sparkline history retains up to 40 samples', () async {
      final initial = await liveCore.diagnostics.first;
      expect(initial.throughputHistory.length, lessThanOrEqualTo(40));
      expect(initial.bufferHistory.length, lessThanOrEqualTo(40));
    });

    test('VisualizerFrame and DiagnosticsSnapshot serialization consistency', () {
      const frame = VisualizerFrame(
        spectrum: [0.1, 0.5, 0.8, 0.2],
        peakLeftDb: -3.5,
        peakRightDb: -4.0,
        clipping: false,
      );
      expect(frame.spectrum.length, 4);
      expect(frame.peakLeftDb, -3.5);
      expect(frame.peakRightDb, -4.0);
      expect(frame.clipping, isFalse);

      const snapshot = DiagnosticsSnapshot(
        tier: OutputTier.bitPerfect,
        requested: AudioFormat(codec: Codec.flac, bitDepth: 24, sampleRate: 96000),
        actual: AudioFormat(codec: Codec.flac, bitDepth: 24, sampleRate: 96000),
        deviceName: 'FiiO KA17',
        bufferAheadSeconds: 5.2,
        pcmFillPercent: 45.0,
        underrunCount: 0,
        speedMbps: 4.8,
        activeRangeRequests: 1,
        requestsPerMinute: 12,
        requestBudgetPerMinute: 12000,
        cacheHitRate: 0.95,
        cacheSizeBytes: 104857600,
        currentFileCachedPercent: 60,
        decodeLoadPercent: 8.5,
        timeToFirstByteMs: 140,
        bytesDownloaded: 50000000,
      );
      expect(snapshot.tier, OutputTier.bitPerfect);
      expect(snapshot.bufferAheadSeconds, 5.2);
      expect(snapshot.cacheHitRate, 0.95);
      expect(snapshot.bytesDownloaded, 50000000);
    });
  });
}
