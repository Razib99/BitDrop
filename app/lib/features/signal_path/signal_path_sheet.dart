import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core_api/commands.dart';
import '../../l10n/l10n.dart';
import '../../providers/core_providers.dart';
import '../../routing/routes.dart';
import '../../widgets/common.dart';
import '../../widgets/signal_path_diagram.dart';

Future<void> showSignalPathSheet(BuildContext context) => showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => const SignalPathSheet(),
    );

/// The honest account of what happened to the audio, from source to ears.
class SignalPathSheet extends ConsumerWidget {
  const SignalPathSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = ref.watch(signalPathProvider).valueOrNull;

    return BottomSheetScaffold(
      title: context.l10n.signalPathTitle,
      subtitle: path == null ? null : 'Live, from the engine',
      child: path == null
          ? const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            )
          : SignalPathDiagram(
              path: path,
              onTurnOffEq: path.dspActive
                  ? () {
                      sendCommand(ref, const SetBypass(true));
                      sendCommand(ref, const SetPreamp(0));
                    }
                  : null,
              onRunSafetyCheck: () {
                Navigator.of(context).pop();
                context.push(Routes.safety);
              },
              onOpenDiagnostics: () {
                Navigator.of(context).pop();
                context.push(Routes.diagnostics);
              },
            ),
    );
  }
}
