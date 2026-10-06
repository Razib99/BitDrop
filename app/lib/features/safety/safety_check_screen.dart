import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core_api/commands.dart';
import '../../l10n/l10n.dart';
import '../../providers/core_providers.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../util/format.dart';

/// Hearing Safety Check — the only blocking modal in BitDrop.
///
/// In bit-perfect mode there is no software volume, so a sensitive IEM on a
/// DAC with no hardware control can play at full scale. This runs once per
/// phone-and-DAC pair before the first bit-perfect playback.
class SafetyCheckScreen extends ConsumerStatefulWidget {
  const SafetyCheckScreen({super.key});

  @override
  ConsumerState<SafetyCheckScreen> createState() => _SafetyCheckScreenState();
}

class _SafetyCheckScreenState extends ConsumerState<SafetyCheckScreen> {
  int _step = 0;
  bool _removedEarphones = false;
  bool? _volumeKeysWork;
  bool _acknowledged = false;

  @override
  Widget build(BuildContext context) {
    final device = ref.watch(outputDeviceProvider).valueOrNull;
    final settings = ref.watch(settingsValueProvider);

    return PopScope(
      // Blocking by design: stepping out mid-check would leave the user
      // without a verdict, which is the thing this flow exists to produce.
      canPop: _step == 0,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Hearing safety check'),
          leading: IconButton(
            icon: const Icon(Icons.close),
            tooltip: context.l10n.actionCancel,
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ),
        body: Column(
          children: [
            LinearProgressIndicator(
              value: (_step + 1) / 3,
              backgroundColor: context.c.surface3,
            ),
            Expanded(
              child: switch (_step) {
                0 => _StepRemove(
                    deviceName: device?.name,
                    checked: _removedEarphones,
                    onChanged: (v) => setState(() => _removedEarphones = v),
                  ),
                1 => _StepVolumeKeys(
                    answer: _volumeKeysWork,
                    onAnswer: (v) => setState(() => _volumeKeysWork = v),
                  ),
                _ => _StepResult(
                    works: _volumeKeysWork ?? false,
                    attenuationDb: settings.safetyAttenuationDb,
                    acknowledged: _acknowledged,
                    onAcknowledge: (v) => setState(() => _acknowledged = v),
                  ),
              },
            ),
            _Footer(
              step: _step,
              canAdvance: switch (_step) {
                0 => _removedEarphones,
                1 => _volumeKeysWork != null,
                _ => (_volumeKeysWork ?? false) || _acknowledged,
              },
              onBack: () => setState(() => _step--),
              onNext: () {
                if (_step < 2) {
                  setState(() => _step++);
                  return;
                }
                final works = _volumeKeysWork ?? false;
                sendCommand(ref, RunSafetyCheck(deviceId: device?.id));
                if (!works) {
                  sendCommand(
                    ref,
                    SetSafetyAttenuation(
                        enabled: true, db: settings.safetyAttenuationDb),
                  );
                }
                Navigator.of(context).pop();
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _StepRemove extends StatelessWidget {
  const _StepRemove({
    required this.deviceName,
    required this.checked,
    required this.onChanged,
  });

  final String? deviceName;
  final bool checked;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return ListView(
      padding: const EdgeInsets.all(Spacing.lg),
      children: [
        Center(
          child: Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              color: c.tierResampled.withOpacity(0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.headset_off,
                size: 56, color: c.tierResampled),
          ),
        ),
        const SizedBox(height: Spacing.xl),
        Text('Remove your earphones', style: context.t.headline),
        const SizedBox(height: Spacing.sm),
        Text(
          'Bit-perfect output bypasses software volume, so BitDrop cannot '
          'turn the sound down before it reaches '
          '${deviceName ?? 'your DAC'}. A sensitive IEM can be dangerously '
          'loud at full scale.',
          style: context.t.body.copyWith(color: c.textSecondary),
        ),
        const SizedBox(height: Spacing.md),
        Text(
          'This check takes about fifteen seconds and is remembered for this '
          'phone and this DAC.',
          style: context.t.bodySmall.copyWith(color: c.textSecondary),
        ),
        const SizedBox(height: Spacing.lg),
        CheckboxListTile(
          value: checked,
          onChanged: (v) => onChanged(v ?? false),
          title: const Text('My earphones are out of my ears'),
          contentPadding: EdgeInsets.zero,
        ),
      ],
    );
  }
}

class _StepVolumeKeys extends StatelessWidget {
  const _StepVolumeKeys({required this.answer, required this.onAnswer});

  final bool? answer;
  final ValueChanged<bool> onAnswer;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return ListView(
      padding: const EdgeInsets.all(Spacing.lg),
      children: [
        Center(
          child: Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              color: c.accent.withOpacity(0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.volume_down, size: 56, color: c.accent),
          ),
        ),
        const SizedBox(height: Spacing.xl),
        Text('Press volume down a few times', style: context.t.headline),
        const SizedBox(height: Spacing.sm),
        Text(
          'A quiet test tone is playing. Watch whether the level below '
          'changes as you press the keys.',
          style: context.t.body.copyWith(color: c.textSecondary),
        ),
        const SizedBox(height: Spacing.lg),
        // Live indicator of whether the keys move the DAC's level.
        Container(
          padding: const EdgeInsets.all(Spacing.md),
          decoration: BoxDecoration(
            color: c.surface2,
            borderRadius: Radii.cardR,
            border: Border.all(color: c.outline),
          ),
          child: Row(
            children: [
              Icon(Icons.graphic_eq, color: c.textSecondary),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Test tone', style: context.t.monoLabel),
                    Text('1 kHz · ${Fmt.db(-40)} · 2 s loop',
                        style: context.t.monoReadout),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: Spacing.lg),
        Text('Did the loudness change?', style: context.t.titleSmall),
        const SizedBox(height: Spacing.xs),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => onAnswer(true),
                style: OutlinedButton.styleFrom(
                  backgroundColor:
                      answer == true ? c.success.withOpacity(0.16) : null,
                  side: BorderSide(
                      color: answer == true ? c.success : c.outline),
                ),
                child: const Text('Yes, it changed'),
              ),
            ),
            const SizedBox(width: Spacing.xs),
            Expanded(
              child: OutlinedButton(
                onPressed: () => onAnswer(false),
                style: OutlinedButton.styleFrom(
                  backgroundColor: answer == false
                      ? c.tierResampled.withOpacity(0.16)
                      : null,
                  side: BorderSide(
                      color: answer == false ? c.tierResampled : c.outline),
                ),
                child: const Text('No, it stayed'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _StepResult extends StatelessWidget {
  const _StepResult({
    required this.works,
    required this.attenuationDb,
    required this.acknowledged,
    required this.onAcknowledge,
  });

  final bool works;
  final double attenuationDb;
  final bool acknowledged;
  final ValueChanged<bool> onAcknowledge;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final color = works ? c.success : c.tierResampled;

    return ListView(
      padding: const EdgeInsets.all(Spacing.lg),
      children: [
        Center(
          child: Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              color: color.withOpacity(0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(
              works ? Icons.verified_outlined : Icons.shield_outlined,
              size: 56,
              color: color,
            ),
          ),
        ),
        const SizedBox(height: Spacing.xl),
        Text(
          works ? 'Hardware volume works' : 'Your DAC has no volume control',
          style: context.t.headline,
        ),
        const SizedBox(height: Spacing.sm),
        Text(
          works
              ? 'Your volume keys drive the DAC directly, so bit-perfect '
                  'playback is safe on this pair. BitDrop will apply no '
                  'digital gain.'
              : 'The volume keys did not change the level, so nothing between '
                  'BitDrop and your ears can turn the sound down.',
          style: context.t.body.copyWith(color: c.textSecondary),
        ),
        if (!works) ...[
          const SizedBox(height: Spacing.md),
          Container(
            padding: const EdgeInsets.all(Spacing.sm),
            decoration: BoxDecoration(
              color: c.tierResampled.withOpacity(0.10),
              borderRadius: Radii.cardR,
              border: Border.all(color: c.tierResampled.withOpacity(0.4)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.shield_outlined,
                        size: 18, color: c.tierResampled),
                    const SizedBox(width: Spacing.xs),
                    Text(
                      'Safety attenuation recommended',
                      style: context.t.titleSmall
                          .copyWith(color: c.tierResampled),
                    ),
                  ],
                ),
                const SizedBox(height: Spacing.xs),
                Text(
                  'BitDrop will apply ${Fmt.db(attenuationDb)} of digital '
                  'attenuation. That is a change to the samples, so the '
                  'output will show as Native rate, not Bit-perfect. You can '
                  'turn it off in Output & Devices.',
                  style:
                      context.t.bodySmall.copyWith(color: c.textSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(height: Spacing.md),
          CheckboxListTile(
            value: acknowledged,
            onChanged: (v) => onAcknowledge(v ?? false),
            title: const Text(
              'I understand the risk and want to continue',
            ),
            contentPadding: EdgeInsets.zero,
          ),
        ],
      ],
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({
    required this.step,
    required this.canAdvance,
    required this.onBack,
    required this.onNext,
  });

  final int step;
  final bool canAdvance;
  final VoidCallback onBack;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(Spacing.md),
          child: Row(
            children: [
              if (step > 0)
                Expanded(
                  child: OutlinedButton(
                    onPressed: onBack,
                    child: Text(context.l10n.actionBack),
                  ),
                ),
              if (step > 0) const SizedBox(width: Spacing.xs),
              Expanded(
                flex: 2,
                child: FilledButton(
                  onPressed: canAdvance ? onNext : null,
                  child: Text(
                    step < 2
                        ? context.l10n.actionContinue
                        : context.l10n.actionDone,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
}
