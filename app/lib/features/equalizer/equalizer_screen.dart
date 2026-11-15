import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core_api/commands.dart';
import '../../core_api/enums.dart';
import '../../core_api/models.dart';
import '../../core_mock/catalog.dart';
import '../../l10n/l10n.dart';
import '../../providers/core_providers.dart';
import '../../routing/routes.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../util/biquad.dart';
import '../../util/format.dart';
import '../../widgets/common.dart';
import '../../widgets/eq_graph.dart';
import '../../widgets/meters.dart';
import 'import_eq_sheet.dart';

/// Equaliser and DSP.
///
/// The banner at the top is the point of the screen: as soon as anything in
/// here alters the samples, it says so, and the Now Playing label changes to
/// match.
class EqualizerScreen extends ConsumerStatefulWidget {
  const EqualizerScreen({super.key});

  @override
  ConsumerState<EqualizerScreen> createState() => _EqualizerScreenState();
}

class _EqualizerScreenState extends ConsumerState<EqualizerScreen> {
  int? _selectedBand;
  bool _abHeld = false;
  bool _abBypassedAudio = false;

  @override
  void dispose() {
    if (_abBypassedAudio) {
      sendCommand(ref, const SetBypass(false));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final eq = ref.watch(eqProvider).valueOrNull;
    final signal = ref.watch(signalPathProvider).valueOrNull;
    final device = ref.watch(outputDeviceProvider).valueOrNull;
    final vis = ref.watch(visualizerProvider).valueOrNull ?? VisualizerFrame.silent;
    final l = context.l10n;

    if (eq == null) {
      return Scaffold(
        appBar: AppBar(title: Text(l.navEq)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final bypassed = eq.bypass || _abHeld;
    final toneBands = Biquad.fromTone(
      eq.bassDb,
      eq.trebleDb,
      bassFreqHz: eq.bassFreqHz,
      trebleFreqHz: eq.trebleFreqHz,
    );
    final stageBands = _stageBands(eq);
    final totalBands = Biquad.composeBands(eq);

    return Scaffold(
      appBar: AppBar(
        title: Text(l.navEq),
        actions: [
          // Master bypass. True bypass: nothing in the chain runs.
          Row(
            children: [
              Text(eq.bypass ? 'Bypassed' : 'Active', style: context.t.label),
              Switch(
                value: !eq.bypass,
                onChanged: (v) => sendCommand(ref, SetBypass(!v)),
              ),
            ],
          ),
          const SizedBox(width: Spacing.xs),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Spacing.xxl),
        children: [
          if (eq.isActive) _ActiveBanner(signal: signal),
          SegmentedTabs<EqMode>(
            values: EqMode.values,
            labels: (m) => switch (m) {
              EqMode.simple => 'Tone & Presets',
              EqMode.graphic => 'Graphic',
              EqMode.parametric => 'Parametric',
            },
            selected: eq.mode,
            onChanged: (m) => sendCommand(ref, SetEqMode(m)),
          ),
          const SizedBox(height: Spacing.sm),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
            child: EqGraph(
              bands: stageBands,
              overlayBands: eq.mode == EqMode.simple ? const [] : toneBands,
              spectrum: vis.spectrum,
              preampDb: eq.preampDb,
              bypassed: bypassed,
              lockFrequency: eq.mode == EqMode.graphic,
              targetCurve: eq.targetCurve,
              selectedBandId: _selectedBand,
              interactive: eq.mode != EqMode.simple && !eq.bypass,
              onSelect: (id) => setState(() => _selectedBand = id),
              onChanged: (bands) {
                if (eq.mode == EqMode.parametric) {
                  sendCommand(ref, SetEqBands(bands));
                } else if (eq.mode == EqMode.graphic) {
                  sendCommand(
                    ref,
                    SetGraphicGains(bands.map((b) => b.gainDb).toList()),
                  );
                }
              },
            ),
          ),
          const SizedBox(height: Spacing.md),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
            child: PreampMeter(
              preampDb: eq.preampDb,
              clippedSamples: eq.clippedSamples,
              peakDb: Biquad.peakDb(totalBands, preampDb: eq.preampDb),
              headroomLabel: eq.headroomLabel,
              effectiveHeadroomDb: Biquad.autoHeadroomOffsetDb(eq, totalBands),
              limiterGrDb: vis.limiterGrDb,
              onCycleHeadroom: () => _cycleHeadroom(eq),
              onChanged: (v) => sendCommand(ref, SetPreamp(v)),
            ),
          ),
          const SizedBox(height: Spacing.sm),
          _AbCompare(
            onChanged: (held) {
              setState(() => _abHeld = held);
              if (held) {
                if (!eq.bypass) {
                  _abBypassedAudio = true;
                  sendCommand(ref, const SetBypass(true));
                }
              } else {
                if (_abBypassedAudio) {
                  _abBypassedAudio = false;
                  sendCommand(ref, const SetBypass(false));
                }
              }
            },
          ),
          _ToneContourDeck(eq: eq),
          _CuratedPresetRail(eq: eq),
          switch (eq.mode) {
            EqMode.parametric => _ParametricControls(
                eq: eq,
                selectedBand: _selectedBand,
                onSelect: (id) => setState(() => _selectedBand = id),
              ),
            EqMode.graphic => _GraphicControls(eq: eq),
            EqMode.simple => const SizedBox.shrink(),
          },
          const SectionHeader(title: 'Presets'),
          ListTile(
            leading: const Icon(Icons.headphones_outlined),
            title: const Text('AutoEQ browser'),
            subtitle: Text(
              eq.presetName ?? 'Find a profile for your IEM or headphones',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push(Routes.autoEq),
          ),
          ListTile(
            leading: const Icon(Icons.file_upload_outlined),
            title: const Text('Import ParametricEQ.txt'),
            subtitle: const Text('Paste or load an AutoEQ export'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => showImportEqSheet(context),
          ),
          if (device != null)
            SwitchListTile(
              value: eq.assignedDeviceName == device.name,
              onChanged: (v) => sendCommand(
                ref,
                AssignEqToDevice(deviceId: device.id, assign: v),
              ),
              secondary: const Icon(Icons.link),
              title: Text('Auto-apply when ${device.name} is connected'),
              subtitle: const Text(
                'The preset switches with the device, so each one keeps its '
                'own tuning.',
              ),
            ),
          _DspSection(eq: eq, signal: signal),
        ],
      ),
    );
  }

  /// Stage bands displayed as draggable nodes for the selected tab.
  List<EqBand> _stageBands(EqState eq) => switch (eq.mode) {
        EqMode.parametric => eq.bands,
        EqMode.graphic => Biquad.fromGraphicGains(
            eq.graphicGains.isEmpty ? List.filled(10, 0.0) : eq.graphicGains,
            Biquad.isoGraphicCenters,
          ),
        EqMode.simple => Biquad.fromTone(
            eq.bassDb,
            eq.trebleDb,
            bassFreqHz: eq.bassFreqHz,
            trebleFreqHz: eq.trebleFreqHz,
          ),
      };

  void _cycleHeadroom(EqState eq) {
    final cmd = switch (eq.headroomModeIndex) {
      0 => const SetHeadroomMode(smartHeadroom: false, autoPreamp: true),
      1 => const SetHeadroomMode(smartHeadroom: false, autoPreamp: false),
      _ => const SetHeadroomMode(smartHeadroom: true, autoPreamp: false),
    };
    sendCommand(ref, cmd);
  }
}

class _ActiveBanner extends StatelessWidget {
  const _ActiveBanner({required this.signal});

  final SignalPath? signal;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    // Only claim a bit-perfect loss when the device could have reached it.
    final couldHaveBeenBitPerfect =
        signal?.device?.maxTier == OutputTier.bitPerfect;

    return Container(
      margin: const EdgeInsets.fromLTRB(
          Spacing.md, Spacing.xs, Spacing.md, Spacing.xs),
      padding: const EdgeInsets.all(Spacing.sm),
      decoration: BoxDecoration(
        color: c.dspActive.withOpacity(0.12),
        borderRadius: Radii.chipR,
        border: Border.all(color: c.dspActive.withOpacity(0.5)),
      ),
      child: Row(
        children: [
          Icon(Icons.graphic_eq, size: 18, color: c.dspActive),
          const SizedBox(width: Spacing.xs),
          Expanded(
            child: Text(
              couldHaveBeenBitPerfect
                  ? 'EQ is active — output is no longer bit-perfect.'
                  : 'EQ is active — the samples are being changed.',
              style: context.t.bodySmall.copyWith(color: c.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}

class _AbCompare extends StatelessWidget {
  const _AbCompare({required this.onChanged});

  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
        child: GestureDetector(
          onTapDown: (_) => onChanged(true),
          onTapUp: (_) => onChanged(false),
          onTapCancel: () => onChanged(false),
          child: OutlinedButton.icon(
            onPressed: () {},
            icon: const Icon(Icons.compare_arrows, size: 18),
            label: const Text('Hold to hear bypass (A/B)'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(double.infinity, Sizes.touchTarget),
            ),
          ),
        ),
      );
}

class _ParametricControls extends ConsumerWidget {
  const _ParametricControls({
    required this.eq,
    required this.selectedBand,
    required this.onSelect,
  });

  final EqState eq;
  final int? selectedBand;
  final ValueChanged<int?> onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          title: 'Bands',
          subtitle: '${eq.bands.length} of 10 · drag the graph or type here',
          actionLabel: eq.bands.length < 10 ? 'Add band' : null,
          onAction: eq.bands.length < 10
              ? () {
                  final nextId = (eq.bands.isEmpty
                          ? 0
                          : eq.bands
                              .map((b) => b.id)
                              .reduce((a, b) => a > b ? a : b)) +
                      1;
                  sendCommand(
                    ref,
                    SetEqBands([
                      ...eq.bands,
                      EqBand(
                        id: nextId,
                        type: BiquadType.peak,
                        frequencyHz: 1000,
                        gainDb: 0,
                        q: 1.0,
                      ),
                    ]),
                  );
                }
              : null,
        ),
        for (final b in eq.bands)
          EqBandRow(
            band: b,
            selected: b.id == selectedBand,
            onSelect: () => onSelect(b.id),
            onChanged: (nb) => sendCommand(
              ref,
              SetEqBands([
                for (final x in eq.bands)
                  if (x.id == nb.id) nb else x,
              ]),
            ),
            onRemove: () => sendCommand(
              ref,
              SetEqBands(eq.bands.where((x) => x.id != b.id).toList()),
            ),
          ),
      ],
    );
  }
}

class _GraphicControls extends ConsumerWidget {
  const _GraphicControls({required this.eq});

  final EqState eq;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final gains =
        eq.graphicGains.isEmpty ? List.filled(10, 0.0) : eq.graphicGains;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(
          title: '10-band graphic',
          subtitle: 'ISO centre frequencies, ±12 dB',
        ),
        SizedBox(
          height: 220,
          child: Row(
            children: [
              for (var i = 0; i < MockCatalog.graphicBands.length; i++)
                Expanded(
                  child: Column(
                    children: [
                      Text(
                        Fmt.db(gains[i], digits: 0),
                        style: context.t.monoLabel
                            .copyWith(color: context.c.textSecondary),
                      ),
                      Expanded(
                        child: RotatedBox(
                          quarterTurns: 3,
                          child: Semantics(
                            slider: true,
                            label:
                                '${Fmt.hzShort(MockCatalog.graphicBands[i].toDouble())} hertz',
                            value: Fmt.db(gains[i]),
                            excludeSemantics: true,
                            child: Slider(
                              value: gains[i].clamp(-12, 12),
                              min: -12,
                              max: 12,
                              divisions: 48,
                              onChanged: (v) {
                                final next = [...gains];
                                next[i] = v;
                                sendCommand(ref, SetGraphicGains(next));
                              },
                            ),
                          ),
                        ),
                      ),
                      Text(
                        Fmt.hzShort(MockCatalog.graphicBands[i].toDouble()),
                        style: context.t.monoLabel
                            .copyWith(color: context.c.textSecondary),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
          child: OutlinedButton.icon(
            onPressed: () =>
                sendCommand(ref, SetGraphicGains(List.filled(10, 0.0))),
            icon: const Icon(Icons.restart_alt, size: 18),
            label: const Text('Reset to flat'),
          ),
        ),
      ],
    );
  }
}

class _ToneContourDeck extends ConsumerWidget {
  const _ToneContourDeck({required this.eq});

  final EqState eq;

  static const _bassFreqs = [40.0, 65.0, 85.0];
  static const _trebleFreqs = [8000.0, 10000.0, 12000.0];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final bassSub = eq.bassDb > 0.5
        ? 'Shelf + 185 Hz mud dip'
        : '${eq.bassFreqHz.round()} Hz low shelf';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          title: 'Tone Contour',
          subtitle: 'Always active · $bassSub',
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
          child: Container(
            padding: const EdgeInsets.all(Spacing.sm),
            decoration: BoxDecoration(
              color: c.surface2,
              borderRadius: Radii.cardR,
              border: Border.all(color: c.outline),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _ToneSlider(
                  label: 'Bass',
                  value: eq.bassDb,
                  onChanged: (v) => sendCommand(ref, SetTone(bassDb: v)),
                ),
                Wrap(
                  spacing: Spacing.xs,
                  children: [
                    for (final hz in _bassFreqs)
                      BitChip(
                        label: '${hz.round()} Hz',
                        selected: (eq.bassFreqHz - hz).abs() < 1.0,
                        onTap: () =>
                            sendCommand(ref, SetTone(bassFreqHz: hz)),
                      ),
                  ],
                ),
                const SizedBox(height: Spacing.xs),
                _ToneSlider(
                  label: 'Treble',
                  value: eq.trebleDb,
                  onChanged: (v) => sendCommand(ref, SetTone(trebleDb: v)),
                ),
                Wrap(
                  spacing: Spacing.xs,
                  children: [
                    for (final hz in _trebleFreqs)
                      BitChip(
                        label: '${(hz / 1000).round()} kHz',
                        selected: (eq.trebleFreqHz - hz).abs() < 1.0,
                        onTap: () =>
                            sendCommand(ref, SetTone(trebleFreqHz: hz)),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

typedef _EqCuratedPreset = ({
  String name,
  double bass,
  double treble,
  double bassFreq,
  List<double> graphic,
});

class _CuratedPresetRail extends ConsumerWidget {
  const _CuratedPresetRail({required this.eq});

  final EqState eq;

  static const _presets = <_EqCuratedPreset>[
    (
      name: 'Flat',
      bass: 0.0,
      treble: 0.0,
      bassFreq: 65.0,
      graphic: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    ),
    (
      name: 'Deep Bass',
      bass: 6.5,
      treble: 1.0,
      bassFreq: 65.0,
      graphic: [3.5, 2.0, 0.5, -1.5, 0.0, 0.5, 1.0, 1.5, 1.0, 0.5],
    ),
    (
      name: 'Bass & Treble',
      bass: 5.0,
      treble: 3.5,
      bassFreq: 65.0,
      graphic: [2.5, 1.5, 0.0, -1.0, -0.5, 0.5, 1.5, 2.5, 3.0, 2.0],
    ),
    (
      name: 'Harman',
      bass: 4.0,
      treble: 1.5,
      bassFreq: 85.0,
      graphic: [2.0, 1.5, 0.5, -0.5, 0.0, 0.5, 2.0, 1.5, 0.5, 0.0],
    ),
    (
      name: 'Warm',
      bass: 3.5,
      treble: -1.5,
      bassFreq: 85.0,
      graphic: [1.5, 2.0, 1.0, 0.5, 0.0, 0.0, -0.5, -1.0, -1.5, -1.5],
    ),
    (
      name: 'Vocal',
      bass: -1.5,
      treble: 2.0,
      bassFreq: 65.0,
      graphic: [-2.0, -1.5, -0.5, 0.0, 1.5, 2.5, 3.0, 2.0, 1.0, 0.5],
    ),
    (
      name: 'V-Shape',
      bass: 5.5,
      treble: 4.5,
      bassFreq: 65.0,
      graphic: [3.0, 2.0, 0.5, -1.5, -2.0, -1.0, 1.0, 2.5, 3.5, 3.0],
    ),
    (
      name: 'Late Night',
      bass: 4.5,
      treble: 2.5,
      bassFreq: 85.0,
      graphic: [2.5, 2.0, 0.5, -0.5, 0.5, 1.0, 1.5, 2.0, 1.5, 1.0],
    ),
    (
      name: 'Rock',
      bass: 4.0,
      treble: 3.0,
      bassFreq: 65.0,
      graphic: [2.5, 1.5, 0.5, -1.0, -0.5, 1.0, 2.5, 3.0, 2.5, 1.5],
    ),
    (
      name: 'Electronic',
      bass: 6.0,
      treble: 3.5,
      bassFreq: 40.0,
      graphic: [4.5, 2.5, 0.5, -1.5, 0.0, 0.5, 1.5, 2.5, 3.0, 2.5],
    ),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(title: 'Quick Presets'),
        SizedBox(
          height: 44,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
            itemCount: _presets.length,
            separatorBuilder: (_, __) => const SizedBox(width: Spacing.xs),
            itemBuilder: (context, i) {
              final preset = _presets[i];
              return BitChip(
                label: preset.name,
                onTap: () {
                  sendCommand(
                    ref,
                    SetTone(
                      bassDb: preset.bass,
                      trebleDb: preset.treble,
                      bassFreqHz: preset.bassFreq,
                    ),
                  );
                  if (eq.mode == EqMode.graphic) {
                    sendCommand(ref, SetGraphicGains(preset.graphic));
                  }
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class _ToneSlider extends StatelessWidget {
  const _ToneSlider({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(label, style: context.t.body),
                const Spacer(),
                Text(Fmt.db(value), style: context.t.monoReadout),
              ],
            ),
            Semantics(
              slider: true,
              label: label,
              value: Fmt.db(value),
              excludeSemantics: true,
              child: Slider(
                value: value.clamp(-12, 12),
                min: -12,
                max: 12,
                divisions: 48,
                onChanged: onChanged,
              ),
            ),
          ],
        ),
      );
}

/// ReplayGain, balance and mono — each one noting its effect on the output.
class _DspSection extends ConsumerWidget {
  const _DspSection({required this.eq, required this.signal});

  final EqState eq;
  final SignalPath? signal;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bitPerfectPossible = signal?.device?.maxTier == OutputTier.bitPerfect;
    const note = 'Applies digital gain, so bit-perfect is not possible '
        'while this is on.';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(title: 'Other processing'),
        ListTile(
          leading: const Icon(Icons.equalizer),
          title: const Text('ReplayGain'),
          subtitle: Text(
            bitPerfectPossible
                ? note
                : 'Evens out loudness between tracks and albums.',
          ),
          trailing: DropdownButton<ReplayGainMode>(
            value: eq.replayGain,
            underline: const SizedBox.shrink(),
            onChanged: (v) {
              if (v != null) sendCommand(ref, SetReplayGain(mode: v));
            },
            items: [
              for (final m in ReplayGainMode.values)
                DropdownMenuItem(
                  value: m,
                  child: Text(switch (m) {
                    ReplayGainMode.off => 'Off',
                    ReplayGainMode.track => 'Track',
                    ReplayGainMode.album => 'Album',
                  }),
                ),
            ],
          ),
        ),
        ListTile(
          leading: const Icon(Icons.headphones),
          title: const Text('BS2B Crossfeed'),
          subtitle: Text(
            bitPerfectPossible
                ? 'Reduces extreme headphone stereo fatigue. $note'
                : '64-bit binaural headphone staging without EQ coloration.',
          ),
          trailing: DropdownButton<CrossfeedPreset>(
            value: eq.crossfeed,
            underline: const SizedBox.shrink(),
            onChanged: (v) {
              if (v != null) sendCommand(ref, SetCrossfeed(v));
            },
            items: [
              for (final preset in CrossfeedPreset.values)
                DropdownMenuItem(
                  value: preset,
                  child: Text(preset.shortLabel),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('Balance', style: context.t.body),
                  const Spacer(),
                  Text(
                    eq.balance == 0
                        ? 'Centre'
                        : (eq.balance < 0
                            ? 'L ${(eq.balance.abs() * 100).round()}%'
                            : 'R ${(eq.balance * 100).round()}%'),
                    style: context.t.monoReadout,
                  ),
                ],
              ),
              Slider(
                value: eq.balance.clamp(-1, 1),
                min: -1,
                max: 1,
                divisions: 40,
                onChanged: (v) => sendCommand(ref, SetTone(balance: v)),
              ),
            ],
          ),
        ),
        SwitchListTile(
          value: eq.mono,
          onChanged: (v) => sendCommand(ref, SetTone(mono: v)),
          secondary: const Icon(Icons.merge_type),
          title: const Text('Mono'),
          subtitle: Text(
            bitPerfectPossible
                ? 'Sums both channels, so bit-perfect is not possible.'
                : 'Sums both channels.',
          ),
        ),
      ],
    );
  }
}
