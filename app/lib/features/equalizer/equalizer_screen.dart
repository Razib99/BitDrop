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

  @override
  Widget build(BuildContext context) {
    final eq = ref.watch(eqProvider).valueOrNull;
    final signal = ref.watch(signalPathProvider).valueOrNull;
    final device = ref.watch(outputDeviceProvider).valueOrNull;
    final l = context.l10n;

    if (eq == null) {
      return Scaffold(
        appBar: AppBar(title: Text(l.navEq)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final bypassed = eq.bypass || _abHeld;

    return Scaffold(
      appBar: AppBar(
        title: Text(l.navEq),
        actions: [
          // Master bypass. True bypass: nothing in the chain runs.
          Row(
            children: [
              Text('Bypass', style: context.t.label),
              Switch(
                value: eq.bypass,
                onChanged: (v) => sendCommand(ref, SetBypass(v)),
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
              EqMode.simple => 'Simple',
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
              bands: _graphBands(eq),
              preampDb: eq.preampDb,
              bypassed: bypassed,
              targetCurve: eq.targetCurve,
              selectedBandId: _selectedBand,
              interactive: eq.mode == EqMode.parametric && !eq.bypass,
              onSelect: (id) => setState(() => _selectedBand = id),
              onChanged: (bands) => sendCommand(ref, SetEqBands(bands)),
            ),
          ),
          const SizedBox(height: Spacing.md),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
            child: PreampMeter(
              preampDb: eq.preampDb,
              clippedSamples: eq.clippedSamples,
              peakDb: Biquad.peakDb(_graphBands(eq), preampDb: eq.preampDb),
              suggestedDb: Biquad.suggestedPreamp(_graphBands(eq)),
              onApplySuggestion: () => sendCommand(
                ref,
                SetPreamp(Biquad.suggestedPreamp(_graphBands(eq))),
              ),
              onChanged: (v) => sendCommand(ref, SetPreamp(v)),
            ),
          ),
          const SizedBox(height: Spacing.sm),
          _AbCompare(
            onChanged: (held) => setState(() => _abHeld = held),
          ),
          switch (eq.mode) {
            EqMode.parametric => _ParametricControls(
                eq: eq,
                selectedBand: _selectedBand,
                onSelect: (id) => setState(() => _selectedBand = id),
              ),
            EqMode.graphic => _GraphicControls(eq: eq),
            EqMode.simple => _SimpleControls(eq: eq),
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

  /// One curve renderer serves all three modes.
  List<EqBand> _graphBands(EqState eq) => switch (eq.mode) {
        EqMode.parametric => eq.bands,
        EqMode.graphic => Biquad.fromGraphicGains(
            eq.graphicGains.isEmpty ? List.filled(10, 0.0) : eq.graphicGains,
            MockCatalog.graphicBands,
          ),
        EqMode.simple => Biquad.fromTone(eq.bassDb, eq.trebleDb),
      };
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

class _SimpleControls extends ConsumerWidget {
  const _SimpleControls({required this.eq});

  final EqState eq;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(title: 'Tone'),
        _ToneSlider(
          label: 'Bass',
          value: eq.bassDb,
          onChanged: (v) => sendCommand(ref, SetTone(bassDb: v)),
        ),
        _ToneSlider(
          label: 'Treble',
          value: eq.trebleDb,
          onChanged: (v) => sendCommand(ref, SetTone(trebleDb: v)),
        ),
        const SectionHeader(title: 'Presets'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
          child: Wrap(
            spacing: Spacing.xs,
            runSpacing: Spacing.xs,
            children: [
              for (final preset in _presets)
                BitChip(
                  label: preset.name,
                  onTap: () => sendCommand(
                    ref,
                    SetTone(bassDb: preset.bass, trebleDb: preset.treble),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// Deliberately few, and no gimmicks: no "3D", no "bass boost".
  static const _presets = [
    (name: 'Flat', bass: 0.0, treble: 0.0),
    (name: 'Warm', bass: 3.0, treble: -1.5),
    (name: 'Bright', bass: -1.0, treble: 3.0),
    (name: 'Loudness', bass: 4.0, treble: 2.5),
    (name: 'Spoken word', bass: -3.0, treble: 1.5),
  ];
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
