import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core_api/commands.dart';
import '../../core_api/models.dart';
import '../../l10n/l10n.dart';
import '../../providers/core_providers.dart';
import '../../routing/routes.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/common.dart';
import '../../widgets/mini_player.dart';
import '../dev/scenario_sheet.dart';

/// Navigation frame: bottom bar on phones, navigation rail at tablet width.
///
/// Hosts the global banner stack, the docked mini player and (in debug builds)
/// the scenario switcher.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final useRail = width >= 840;
    final l = context.l10n;

    // One-shot core events become snackbars.
    ref.listen(coreEventsProvider, (_, next) {
      final event = next.valueOrNull;
      if (event == null || !mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(event.message)));
    });

    final destinations = <_Dest>[
      _Dest(Routes.home, Icons.home_outlined, Icons.home, l.navHome),
      _Dest(Routes.library, Icons.library_music_outlined, Icons.library_music,
          l.navLibrary),
      _Dest(Routes.search, Icons.search_outlined, Icons.search, l.navSearch),
      _Dest(Routes.sources, Icons.cloud_outlined, Icons.cloud, l.navSources),
    ];

    final location = GoRouterState.of(context).uri.path;
    var index = destinations.indexWhere((d) => location.startsWith(d.path));
    if (index < 0) index = 0;

    final body = Column(
      children: [
        const _BannerStack(),
        Expanded(child: widget.child),
      ],
    );

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: useRail
            ? Row(
                children: [
                  _Rail(
                    destinations: destinations,
                    index: index,
                    onSelect: (i) => context.go(destinations[i].path),
                  ),
                  VerticalDivider(width: 1, color: context.c.outline),
                  Expanded(child: body),
                ],
              )
            : body,
      ),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const MiniPlayer(),
          if (!useRail)
            NavigationBar(
              selectedIndex: index,
              onDestinationSelected: (i) => context.go(destinations[i].path),
              destinations: [
                for (final d in destinations)
                  NavigationDestination(
                    icon: Icon(d.icon),
                    selectedIcon: Icon(d.selectedIcon),
                    label: d.label,
                  ),
              ],
            ),
        ],
      ),
      floatingActionButton: kDebugMode
          ? Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.sizeOf(context).height * 0.08,
              ),
              child: const ScenarioFab(),
            )
          : null,
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
    );
  }
}

class _Dest {
  const _Dest(this.path, this.icon, this.selectedIcon, this.label);
  final String path;
  final IconData icon;
  final IconData selectedIcon;
  final String label;
}

class _Rail extends StatelessWidget {
  const _Rail({
    required this.destinations,
    required this.index,
    required this.onSelect,
  });

  final List<_Dest> destinations;
  final int index;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) => NavigationRail(
        selectedIndex: index,
        onDestinationSelected: onSelect,
        labelType: NavigationRailLabelType.all,
        destinations: [
          for (final d in destinations)
            NavigationRailDestination(
              icon: Icon(d.icon),
              selectedIcon: Icon(d.selectedIcon),
              label: Text(d.label),
            ),
        ],
      );
}

/// Global banners, newest first, directly under the status bar.
class _BannerStack extends ConsumerWidget {
  const _BannerStack();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final banners = ref.watch(bannersProvider).valueOrNull ?? const <AppBanner>[];
    if (banners.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: Spacing.xs),
      child: Column(
        children: [
          for (final b in banners.take(3))
            StatusBanner.fromBanner(
              b,
              onAction: b.actionCommandId == null
                  ? null
                  : () => _handleAction(context, ref, b),
              onDismiss: () => sendCommand(ref, DismissBanner(b.id)),
            ),
        ],
      ),
    );
  }

  void _handleAction(BuildContext context, WidgetRef ref, AppBanner b) {
    switch (b.actionCommandId) {
      case 'reconnect':
        final sources = ref.read(sourcesProvider).valueOrNull;
        if (sources != null && sources.isNotEmpty) {
          sendCommand(ref, ReconnectSource(sources.first.id));
        }
      case 'storage':
        context.push(Routes.storage);
      case 'output':
        context.push(Routes.output);
    }
  }
}
