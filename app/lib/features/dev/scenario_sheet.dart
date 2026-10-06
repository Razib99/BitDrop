import 'package:file_picker/file_picker.dart' as file_picker;
import 'package:bitdrop/src/rust/api/simple.dart' as rust_api;
import '../../core_mock/catalog.dart';
import '../../core_api/models.dart';
import '../../core_api/enums.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core_api/commands.dart';
import '../../core_api/settings.dart';
import '../../core_mock/scenarios.dart';
import '../../l10n/l10n.dart';
import '../../providers/core_providers.dart';
import '../../routing/routes.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/common.dart';
import '../../widgets/indicators.dart';

/// Debug-only entry point to the scenario switcher.
class ScenarioFab extends ConsumerWidget {
  const ScenarioFab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scenario = ref.watch(currentScenarioProvider);
    return FloatingActionButton.small(
      heroTag: 'scenario-fab',
      tooltip: 'Scenario: ${scenario.name}',
      backgroundColor: context.c.surface3,
      foregroundColor: context.c.textPrimary,
      onPressed: () => showScenarioSheet(context),
      child: const Icon(Icons.science_outlined),
    );
  }
}

Future<void> showScenarioSheet(BuildContext context) => showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => const ScenarioSheet(),
    );

/// Switches the mock core between the scenarios in Section 9.1, and carries
/// the theme and text-scale presets used for the accessibility checks.
class ScenarioSheet extends ConsumerWidget {
  const ScenarioSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final current = ref.watch(currentScenarioProvider);
    final settings = ref.watch(settingsValueProvider);

    return BottomSheetScaffold(
      title: context.l10n.scenarioSwitcher,
      subtitle: 'Debug builds only · switches the mock core live',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(title: 'Appearance'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
            child: Wrap(
              spacing: Spacing.xs,
              runSpacing: Spacing.xs,
              children: [
                for (final m in AppThemeMode.values)
                  BitChip(
                    label: switch (m) {
                      AppThemeMode.system => context.l10n.themeSystem,
                      AppThemeMode.light => context.l10n.themeLight,
                      AppThemeMode.dark => context.l10n.themeDark,
                    },
                    icon: switch (m) {
                      AppThemeMode.system => Icons.brightness_auto,
                      AppThemeMode.light => Icons.light_mode,
                      AppThemeMode.dark => Icons.dark_mode,
                    },
                    selected: settings.themeMode == m,
                    onTap: () => sendCommand(
                        ref, SetSetting(key: 'themeMode', value: m)),
                  ),
                BitChip(
                  label: 'OLED black',
                  icon: Icons.contrast,
                  selected: settings.oledBlack,
                  onTap: () => sendCommand(
                    ref,
                    SetSetting(key: 'oledBlack', value: !settings.oledBlack),
                  ),
                ),
                BitChip(
                  label: 'Reduce motion',
                  icon: Icons.animation,
                  selected: settings.reduceMotion,
                  onTap: () => sendCommand(
                    ref,
                    SetSetting(
                        key: 'reduceMotion', value: !settings.reduceMotion),
                  ),
                ),
              ],
            ),
          ),
          SectionHeader(title: context.l10n.textScale),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
            child: Wrap(
              spacing: Spacing.xs,
              children: [
                for (final s in [1.0, 1.3, 2.0])
                  BitChip(
                    label: '${(s * 100).round()}%',
                    mono: true,
                    selected: (settings.textScale - s).abs() < 0.01,
                    onTap: () => sendCommand(
                        ref, SetSetting(key: 'textScale', value: s)),
                  ),
              ],
            ),
          ),
          const SectionHeader(title: 'Scenarios'),
          for (final s in Scenarios.all)
            _ScenarioRow(
              scenario: s,
              selected: s.id == current.id,
              onTap: () {
                switchScenario(ref, s);
                Navigator.of(context).pop();
              },
            ),
          const SectionHeader(title: 'Developer'),
          ListTile(
            leading: const Icon(Icons.folder_special),
            title: const Text('Scan Real Library (Music folder)'),
            subtitle: const Text('Scans /home/razib/Desktop/BitDrop/Music & replaces mock data'),
            trailing: const Icon(Icons.refresh),
            onTap: () async {
              Navigator.of(context).pop();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Scanning Music folder...')),
              );
              try {
                final results = rust_api.scanDirectory(path: '/home/razib/Desktop/BitDrop/Music');
                
                final newAlbums = <Album>[];
                final newTracks = <Track>[];
                
                final albumsMap = <String, List<rust_api.TrackMetadata>>{};
                for (final meta in results) {
                  albumsMap.putIfAbsent(meta.album, () => []).add(meta);
                }
                
                for (final albumTitle in albumsMap.keys) {
                  final tracks = albumsMap[albumTitle]!;
                  final first = tracks.first;
                  final albumId = 'real_album_${albumTitle.hashCode}';
                  final artistId = 'real_artist_${first.artist.hashCode}';
                  
                  final duration = tracks.fold<int>(0, (p, c) => p + c.durationMs);
                  final size = tracks.length * 30000000;
                  
                  newAlbums.add(Album(
                    id: albumId,
                    title: albumTitle,
                    artist: first.artist,
                    artistId: artistId,
                    trackCount: tracks.length,
                    durationMs: duration,
                    sizeBytes: size,
                    format: AudioFormat(codec: Codec.flac, bitDepth: 16, sampleRate: first.sampleRate),
                    availability: Availability.cached,
                    artwork: Artwork(seed: albumTitle.hashCode, dominantColor: 0xFF556677),
                  ));
                  
                  for (final meta in tracks) {
                    newTracks.add(Track(
                      id: meta.path,
                      title: meta.title,
                      artist: meta.artist,
                      albumTitle: albumTitle,
                      albumId: albumId,
                      durationMs: meta.durationMs,
                      format: AudioFormat(codec: Codec.flac, bitDepth: 16, sampleRate: meta.sampleRate),
                      availability: Availability.cached,
                      sizeBytes: 30000000,
                      artwork: Artwork(seed: albumTitle.hashCode, dominantColor: 0xFF556677),
                    ));
                  }
                }
                
                MockCatalog.albums.clear();
                MockCatalog.albums.addAll(newAlbums);
                MockCatalog.tracks.clear();
                MockCatalog.tracks.addAll(newTracks); MockCatalog.resetCache();
                
                // Force a reload in the UI
                ref.read(scenarioRevisionProvider.notifier).state++;
                
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('✅ Loaded ${newAlbums.length} albums, ${newTracks.length} tracks from disk!')),
                );
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('❌ Error scanning: $e')),
                );
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.audio_file_outlined),
            title: const Text('Test Rust Audio Engine (FLAC)'),
            subtitle: const Text('Pick a FLAC file to decode via FFI'),
            trailing: const Icon(Icons.bolt),
            onTap: () async {
              Navigator.of(context).pop(); // dismiss sheet
              
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Pick a FLAC file...')),
              );
              
              final result = await file_picker.FilePicker.platform.pickFiles(
                type: file_picker.FileType.custom,
                allowedExtensions: ['flac', 'wav'],
                withData: true,
              );
              
              if (result != null && result.files.single.bytes != null) {
                try {
                  final bytes = result.files.single.bytes!;
                  // We need to convert Uint8List to List<int>
                  final decoded = rust_api.decodeFlacFull(audioData: bytes.toList());
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text('✅ Rust Success: ${decoded.sampleRate}Hz, ${decoded.channels}Ch. Extracted ${decoded.firstFrameSamples.length} samples.'),
                    duration: const Duration(seconds: 5),
                  ));
                } catch (e) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text('❌ Rust FFI Error: $e'),
                    duration: const Duration(seconds: 5),
                  ));
                }
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.widgets_outlined),
            title: Text(context.l10n.componentGallery),
            subtitle: const Text('Every component, in every state'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).pop();
              context.push(Routes.gallery);
            },
          ),
          ListTile(
            leading: const Icon(Icons.monitor_heart_outlined),
            title: Text(context.l10n.openDiagnostics),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).pop();
              context.push(Routes.diagnostics);
            },
          ),
          SizedBox(height: Spacing.md, child: ColoredBox(color: c.surface1)),
        ],
      ),
    );
  }
}

class _ScenarioRow extends StatelessWidget {
  const _ScenarioRow({
    required this.scenario,
    required this.selected,
    required this.onTap,
  });

  final Scenario scenario;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return InkWell(
      onTap: onTap,
      child: Container(
        color: selected ? c.accent.withOpacity(0.12) : null,
        padding: const EdgeInsets.symmetric(
            horizontal: Spacing.md, vertical: Spacing.sm),
        child: Row(
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_off,
              size: 18,
              color: selected ? c.accent : c.textTertiary,
            ),
            const SizedBox(width: Spacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(scenario.name, style: context.t.body),
                  const SizedBox(height: 2),
                  Text(
                    scenario.summary,
                    style: context.t.bodySmall.copyWith(color: c.textSecondary),
                  ),
                ],
              ),
            ),
            const SizedBox(width: Spacing.xs),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                TierChip(tier: scenario.tier, dense: true),
                if (scenario.dspActive) ...[
                  const SizedBox(height: 3),
                  const DspBadge(dense: true),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
