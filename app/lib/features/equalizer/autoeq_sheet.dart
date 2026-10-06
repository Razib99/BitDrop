import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core_api/commands.dart';
import '../../core_api/models.dart';
import '../../l10n/l10n.dart';
import '../../providers/core_providers.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../util/format.dart';
import '../../widgets/common.dart';
import '../../widgets/eq_graph.dart';
import 'import_eq_sheet.dart';

/// AutoEQ browser: search by headphone or IEM model, preview the curve, apply.
///
/// Every result names its measurement source and target, because an AutoEQ
/// profile is only as good as the measurement behind it.
class AutoEqScreen extends ConsumerStatefulWidget {
  const AutoEqScreen({super.key});

  @override
  ConsumerState<AutoEqScreen> createState() => _AutoEqScreenState();
}

class _AutoEqScreenState extends ConsumerState<AutoEqScreen> {
  final _controller = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final results = ref.watch(autoEqSearchProvider(_query));
    final device = ref.watch(outputDeviceProvider).valueOrNull;

    return Scaffold(
      appBar: AppBar(title: const Text('AutoEQ')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(Spacing.md),
            child: TextField(
              controller: _controller,
              autofocus: true,
              onChanged: (v) => setState(() => _query = v),
              decoration: InputDecoration(
                hintText: device == null
                    ? 'Search by model, e.g. "Titan X"'
                    : 'Search by model · ${device.name} is connected',
                prefixIcon: const Icon(Icons.search),
              ),
            ),
          ),
          Expanded(
            child: results.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => EmptyState(
                icon: Icons.error_outline,
                title: 'Search failed',
                message: '$e',
              ),
              data: (profiles) {
                if (profiles.isEmpty) {
                  return EmptyState(
                    icon: Icons.headphones_outlined,
                    title: 'No profile for "$_query"',
                    message:
                        'AutoEQ does not have a measurement for that model '
                        'yet. You can import a ParametricEQ.txt instead.',
                    actionLabel: 'Import a file',
                    onAction: () => showImportEqSheet(context),
                  );
                }
                return ListView.builder(
                  itemCount: profiles.length,
                  itemBuilder: (context, i) =>
                      _ProfileCard(profile: profiles[i]),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ProfileCard extends ConsumerWidget {
  const _ProfileCard({required this.profile});

  final AutoEqProfile profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    return Container(
      margin: const EdgeInsets.fromLTRB(Spacing.md, 0, Spacing.md, Spacing.sm),
      decoration: BoxDecoration(
        color: c.surface1,
        borderRadius: Radii.cardR,
        border: Border.all(color: c.outline),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(Spacing.sm),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(profile.model, style: context.t.titleSmall),
                      const SizedBox(height: 2),
                      Text(
                        '${profile.measurementSource} · target '
                        '${profile.target}',
                        style: context.t.bodySmall
                            .copyWith(color: c.textSecondary),
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text('${profile.bands.length} bands',
                        style: context.t.monoLabel
                            .copyWith(color: c.textSecondary)),
                    Text(
                      'preamp ${Fmt.db(profile.suggestedPreampDb)}',
                      style:
                          context.t.monoLabel.copyWith(color: c.textSecondary),
                    ),
                  ],
                ),
              ],
            ),
          ),
          // Curve preview, non-interactive.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
            child: EqGraph(
              bands: profile.bands,
              preampDb: profile.suggestedPreampDb,
              interactive: false,
              height: 120,
              onChanged: (_) {},
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(Spacing.sm),
            child: Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () {
                      sendCommand(ref, ApplyAutoEqProfile(profile.id));
                      Navigator.of(context).maybePop();
                    },
                    icon: const Icon(Icons.check, size: 18),
                    label: Text(context.l10n.actionApply),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
