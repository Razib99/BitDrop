import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core_api/commands.dart';
import '../../l10n/l10n.dart';
import '../../providers/core_providers.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/common.dart';

Future<void> showImportEqSheet(BuildContext context) => showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => const ImportEqSheet(),
    );

/// Paste an AutoEQ `ParametricEQ.txt`. The core parses it, so the UI never
/// has to understand the format.
class ImportEqSheet extends ConsumerStatefulWidget {
  const ImportEqSheet({super.key});

  @override
  ConsumerState<ImportEqSheet> createState() => _ImportEqSheetState();
}

class _ImportEqSheetState extends ConsumerState<ImportEqSheet> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BottomSheetScaffold(
      title: 'Import a preset',
      subtitle: 'AutoEQ ParametricEQ.txt',
      child: Padding(
        padding: const EdgeInsets.all(Spacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _controller,
              maxLines: 8,
              style: context.t.monoReadout,
              decoration: const InputDecoration(
                hintText: 'Preamp: -6.2 dB\n'
                    'Filter 1: ON LSC Fc 105 Hz Gain 3.4 dB Q 0.70\n'
                    'Filter 2: ON PK Fc 212 Hz Gain -1.8 dB Q 1.10',
              ),
            ),
            const SizedBox(height: Spacing.sm),
            Text(
              'Paste the file contents. Filters marked OFF are imported but '
              'left disabled.',
              style:
                  context.t.bodySmall.copyWith(color: context.c.textSecondary),
            ),
            const SizedBox(height: Spacing.md),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _controller.text = _sample,
                    icon: const Icon(Icons.description_outlined, size: 18),
                    label: const Text('Paste a sample'),
                  ),
                ),
                const SizedBox(width: Spacing.xs),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _controller.text.trim().isEmpty
                        ? null
                        : () {
                            sendCommand(
                                ref, ImportParametricEq(_controller.text));
                            Navigator.of(context).pop();
                          },
                    icon: const Icon(Icons.check, size: 18),
                    label: Text(context.l10n.actionImport),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static const _sample = '''Preamp: -6.2 dB
Filter 1: ON LSC Fc 105 Hz Gain 3.4 dB Q 0.70
Filter 2: ON PK Fc 212 Hz Gain -1.8 dB Q 1.10
Filter 3: ON PK Fc 1150 Hz Gain 1.2 dB Q 1.40
Filter 4: ON PK Fc 2900 Hz Gain -2.6 dB Q 2.20
Filter 5: ON PK Fc 5200 Hz Gain 2.1 dB Q 2.80
Filter 6: ON PK Fc 7800 Hz Gain -3.2 dB Q 3.40
Filter 7: ON HSC Fc 10500 Hz Gain 1.6 dB Q 0.70''';
}
