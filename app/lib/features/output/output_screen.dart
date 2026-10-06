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
import '../../util/format.dart';
import '../../widgets/cards.dart';
import '../../widgets/common.dart';
import '../../widgets/indicators.dart';
import '../signal_path/signal_path_sheet.dart';

/// Output & Devices: what is connected, what it can do, and what BitDrop is
/// actually doing with it.
class OutputScreen extends ConsumerWidget {
  const OutputScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final device = ref.watch(outputDeviceProvider).valueOrNull;
    final signal = ref.watch(signalPathProvider).valueOrNull;
    final profiles = ref.watch(deviceProfilesProvider).valueOrNull ?? const [];
    final settings = ref.watch(settingsValueProvider);
    final l = context.l10n;

    return Scaffold(
      appBar: AppBar(title: Text(l.navOutput)),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Spacing.xxl),
        children: [
          if (device == null)
            const EmptyState(
              icon: Icons.headset_off_outlined,
              title: 'No output device',
              message: 'Plug in a USB DAC or connect headphones.',
            )
          else ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  Spacing.md, Spacing.xs, Spacing.md, 0),
              child: DeviceCard(
                device: device,
                tier: signal?.tier ?? OutputTier.unknown,
                profile: profiles.cast<DeviceProfile?>().firstWhere(
                    (p) => p!.deviceId == device.id,
                    orElse: () => null),
                note: device.type == DeviceType.bluetooth
                    ? 'Bluetooth uses its own codec — lossless bit-perfect '
                        'is not possible on any phone.'
                    : null,
                onRunSafetyCheck: () => context.push(Routes.safety),
              ),
            ),
            if (signal != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    Spacing.md, Spacing.sm, Spacing.md, 0),
                child: OutlinedButton.icon(
                  onPressed: () => showSignalPathSheet(context),
                  icon: Icon(TierChip.iconFor(signal.tier), size: 18),
                  label: const Text('See the full signal path'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(double.infinity, Sizes.touchTarget),
                  ),
                ),
              ),
          ],
          const SectionHeader(title: 'Volume'),
          _VolumePanel(signal: signal),
          const SectionHeader(
            title: 'Hearing safety',
            subtitle: 'Needed when software volume is bypassed',
          ),
          SwitchListTile(
            value: settings.safetyAttenuationEnabled,
            onChanged: (v) =>
                sendCommand(ref, SetSafetyAttenuation(enabled: v)),
            secondary: const Icon(Icons.shield_outlined),
            title: Text(
              'Safety attenuation '
              '(${Fmt.db(settings.safetyAttenuationDb)})',
            ),
            subtitle: const Text(
              'Protects sensitive IEMs on a DAC with no volume control. '
              'It applies digital gain, so output becomes Native rate.',
            ),
          ),
          ListTile(
            leading: const Icon(Icons.hearing),
            title: const Text('Run safety check'),
            subtitle: const Text('Remembered per device'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push(Routes.safety),
          ),
          const SectionHeader(
            title: 'Known devices',
            subtitle: 'Each keeps its own EQ, volume and safety settings',
          ),
          for (final d in MockCatalog.knownDevices)
            _KnownDeviceRow(
              device: d,
              profile: profiles
                  .cast<DeviceProfile?>()
                  .firstWhere((p) => p!.deviceId == d.id, orElse: () => null),
              connected: d.id == device?.id,
            ),
          const SectionHeader(title: 'Advanced'),
          SwitchListTile(
            value: settings.preferBitPerfect,
            onChanged: (v) =>
                sendCommand(ref, SetSetting(key: 'preferBitPerfect', value: v)),
            secondary: const Icon(Icons.diamond_outlined),
            title: const Text('Prefer bit-perfect when available'),
            subtitle: const Text(
              'Asks Android for an untouched path. Needs Android 14 or later '
              'and a DAC that supports it.',
            ),
          ),
          const ListTile(
            leading: Icon(Icons.usb_off),
            title: Text('Direct USB driver'),
            subtitle: Text(
              'Coming later. Would bypass the Android mixer entirely on '
              'phones that cannot reach bit-perfect.',
            ),
            enabled: false,
          ),
        ],
      ),
    );
  }
}

/// In-app fine volume, in dB, labelled with what it actually controls.
class _VolumePanel extends ConsumerStatefulWidget {
  const _VolumePanel({required this.signal});

  final SignalPath? signal;

  @override
  ConsumerState<_VolumePanel> createState() => _VolumePanelState();
}

class _VolumePanelState extends ConsumerState<_VolumePanel> {
  double _db = -14;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final mode = widget.signal?.volume ?? VolumeMode.system;
    final dacOwned = mode == VolumeMode.dacHardware;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                dacOwned ? Icons.lock_outline : Icons.volume_up_outlined,
                size: 16,
                color: c.textSecondary,
              ),
              const SizedBox(width: Spacing.xxs),
              Expanded(
                child: Text(
                  switch (mode) {
                    VolumeMode.dacHardware => 'Hardware (DAC)',
                    VolumeMode.softwareDithered => 'Digital (24-bit, dithered)',
                    VolumeMode.system => 'System',
                  },
                  style: context.t.titleSmall,
                ),
              ),
              if (!dacOwned) Text(Fmt.db(_db), style: context.t.monoReadout),
            ],
          ),
          const SizedBox(height: Spacing.xxs),
          if (dacOwned)
            Text(
              'BitDrop applies no digital gain in this mode. Use the volume '
              'keys, which drive the DAC directly.',
              style: context.t.bodySmall.copyWith(color: c.textSecondary),
            )
          else
            Semantics(
              slider: true,
              label: 'Volume',
              value: Fmt.db(_db),
              excludeSemantics: true,
              child: Slider(
                value: _db.clamp(-60, 0),
                min: -60,
                max: 0,
                divisions: 60,
                label: Fmt.db(_db),
                onChanged: (v) {
                  setState(() => _db = v);
                  sendCommand(ref, SetVolumeDb(v));
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _KnownDeviceRow extends StatelessWidget {
  const _KnownDeviceRow({
    required this.device,
    required this.profile,
    required this.connected,
  });

  final OutputDevice device;
  final DeviceProfile? profile;
  final bool connected;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return ListTile(
      leading: Icon(switch (device.type) {
        DeviceType.usb => Icons.usb,
        DeviceType.bluetooth => Icons.bluetooth,
        DeviceType.phoneSpeaker => Icons.smartphone,
        _ => Icons.headphones,
      }),
      title: Row(
        children: [
          Flexible(child: Text(device.name, overflow: TextOverflow.ellipsis)),
          if (connected) ...[
            const SizedBox(width: Spacing.xs),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: c.success.withOpacity(0.18),
                borderRadius: Radii.badgeR,
              ),
              child: Text('Connected',
                  style: context.t.monoLabel.copyWith(color: c.success)),
            ),
          ],
        ],
      ),
      subtitle: Text(
        profile == null
            ? 'No saved profile'
            : [
                if (profile!.eqPresetName != null) profile!.eqPresetName!,
                'RG ${profile!.replayGain.name}',
                if (profile!.preferredVolumeDb != null)
                  Fmt.db(profile!.preferredVolumeDb!),
              ].join(' · '),
      ),
      trailing: TierChip(tier: device.maxTier, dense: true),
    );
  }
}
