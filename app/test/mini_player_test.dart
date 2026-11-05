import 'package:bitdrop/core_api/commands.dart';
import 'package:bitdrop/core_api/enums.dart';
import 'package:bitdrop/core_api/models.dart';
import 'package:bitdrop/core_mock/mock_core.dart';
import 'package:bitdrop/l10n/app_localizations.dart';
import 'package:bitdrop/providers/core_providers.dart';
import 'package:bitdrop/theme/app_theme.dart';
import 'package:bitdrop/widgets/mini_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _RecordingCore extends MockBitDropCore {
  final List<PlayerCommand> recorded = [];

  @override
  Future<void> send(PlayerCommand cmd) async {
    recorded.add(cmd);
    return super.send(cmd);
  }
}

void main() {
  const dummyTrack = Track(
    id: 'track-mini-1',
    title: 'Solar Echoes',
    artist: 'Nora En Pure',
    albumId: 'album-mini-1',
    albumTitle: 'Deep Horizons',
    trackNumber: 1,
    discNumber: 1,
    durationMs: 240000,
    sizeBytes: 1024 * 1024 * 25,
    artwork: Artwork(seed: 77, dominantColor: 0xFF1E293B),
    format: AudioFormat(
      codec: Codec.flac,
      bitDepth: 24,
      sampleRate: 96000,
      channels: 2,
    ),
    availability: Availability.cached,
  );

  const dummyNowPlaying = NowPlaying(
    track: dummyTrack,
    contextLabel: 'Album · Deep Horizons',
  );

  testWidgets('MiniPlayer displays previous, play/pause, and next buttons and dispatches commands',
      (tester) async {
    final core = _RecordingCore();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          coreProvider.overrideWithValue(core),
          nowPlayingProvider.overrideWith((ref) => Stream.value(dummyNowPlaying)),
          playbackProvider.overrideWith((ref) => Stream.value(const PlayingState())),
        ],
        child: MaterialApp(
          theme: AppTheme.dark(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(
            bottomNavigationBar: MiniPlayer(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Solar Echoes'), findsOneWidget);
    expect(find.text('Nora En Pure'), findsOneWidget);

    // Verify Previous, Pause (since playing), and Next buttons are present
    expect(find.byIcon(Icons.skip_previous_rounded), findsOneWidget);
    expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
    expect(find.byIcon(Icons.skip_next_rounded), findsOneWidget);

    // Tap Previous
    await tester.tap(find.byIcon(Icons.skip_previous_rounded));
    await tester.pump();
    expect(core.recorded.last, isA<Previous>());

    // Tap Pause
    await tester.tap(find.byIcon(Icons.pause_rounded));
    await tester.pump();
    expect(core.recorded.last, isA<Pause>());

    // Tap Next
    await tester.tap(find.byIcon(Icons.skip_next_rounded));
    await tester.pump();
    expect(core.recorded.last, isA<Next>());

    core.dispose();
  });

  testWidgets('MiniPlayer displays play icon when paused and sends Resume on tap',
      (tester) async {
    final core = _RecordingCore();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          coreProvider.overrideWithValue(core),
          nowPlayingProvider.overrideWith((ref) => Stream.value(dummyNowPlaying)),
          playbackProvider.overrideWith((ref) => Stream.value(const PausedState())),
        ],
        child: MaterialApp(
          theme: AppTheme.dark(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(
            bottomNavigationBar: MiniPlayer(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);

    // Tap Play
    await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    await tester.pump();
    expect(core.recorded.last, isA<Resume>());

    core.dispose();
  });

  testWidgets('MiniPlayer displays progress spinner when buffering without shifting controls',
      (tester) async {
    final core = _RecordingCore();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          coreProvider.overrideWithValue(core),
          nowPlayingProvider.overrideWith((ref) => Stream.value(dummyNowPlaying)),
          playbackProvider.overrideWith((ref) => Stream.value(
                const BufferingState(bufferedMs: 500, targetMs: 2000, attempt: 1),
              )),
        ],
        child: MaterialApp(
          theme: AppTheme.dark(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(
            bottomNavigationBar: MiniPlayer(),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byIcon(Icons.skip_previous_rounded), findsOneWidget);
    expect(find.byIcon(Icons.skip_next_rounded), findsOneWidget);

    core.dispose();
  });
}
