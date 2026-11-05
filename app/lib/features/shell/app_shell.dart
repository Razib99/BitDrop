import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core_api/commands.dart';
import '../../core_api/models.dart';
import '../../l10n/l10n.dart';
import '../../providers/core_providers.dart';
import '../../providers/player_sheet_provider.dart';
import '../../routing/routes.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/common.dart';
import '../../widgets/expanding_player_sheet.dart';
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

class _AppShellState extends ConsumerState<AppShell>
    with SingleTickerProviderStateMixin {
  late final AnimationController _playerAnimController;
  late final PlayerSheetController _sheetController;

  @override
  void initState() {
    super.initState();
    _playerAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    );
    _sheetController = ref.read(playerSheetControllerProvider);
    _sheetController.attach(_playerAnimController);
  }

  @override
  void dispose() {
    _sheetController.detach(_playerAnimController);
    _playerAnimController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final useRail = width >= 840;
    final l = context.l10n;

    final destinations = <_Dest>[
      _Dest(Routes.home, Icons.home_outlined, Icons.home, l.navHome),
      _Dest(Routes.library, Icons.library_music_outlined, Icons.library_music,
          l.navLibrary),
      _Dest(Routes.search, Icons.search_outlined, Icons.search, l.navSearch),
      _Dest(Routes.sources, Icons.cloud_outlined, Icons.cloud, l.navSources),
    ];

    final location = GoRouterState.of(context).uri.path;
    final isHome = location == Routes.home || location == '/';
    var index = destinations.indexWhere((d) => location.startsWith(d.path));
    if (index < 0) index = 0;

    final sheetController = ref.watch(playerSheetControllerProvider);
    final sheetProgress = sheetController.progress;

    final body = Column(
      children: [
        const _BannerStack(),
        Expanded(
          child: Padding(
            padding: EdgeInsets.only(
              bottom: useRail
                  ? 0.0
                  : (isHome ? 80.0 : (80.0 + Sizes.miniPlayerHeight)),
            ),
            child: widget.child,
          ),
        ),
      ],
    );

    return Scaffold(
      extendBody: true,
      body: useRail
          ? SafeArea(
              bottom: false,
              child: Row(
                children: [
                  _Rail(
                    destinations: destinations,
                    index: index,
                    onSelect: (i) {
                      if (destinations[i].path == Routes.library) {
                        ref.read(libraryTabProvider.notifier).state =
                            LibraryTab.tracks;
                      }
                      context.go(destinations[i].path);
                    },
                  ),
                  VerticalDivider(width: 1, color: context.c.outline),
                  Expanded(
                    child: Stack(
                      children: [
                        body,
                        ExpandingPlayerSheet(
                          isHome: isHome,
                          useRail: true,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            )
          : Stack(
              children: [
                // 1. Full page content (banner stack + child)
                Positioned.fill(
                  child: SafeArea(
                    bottom: false,
                    child: body,
                  ),
                ),

                // 2. Navigation bar, translating down off screen as sheet expands
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Transform.translate(
                    offset: Offset(0, sheetProgress * 120.0),
                    child: NavigationBar(
                      selectedIndex: index,
                      onDestinationSelected: (i) {
                        if (destinations[i].path == Routes.library) {
                          ref.read(libraryTabProvider.notifier).state =
                              LibraryTab.tracks;
                        }
                        context.go(destinations[i].path);
                      },
                      destinations: [
                        for (final d in destinations)
                          NavigationDestination(
                            icon: Icon(d.icon),
                            selectedIcon: Icon(d.selectedIcon),
                            label: d.label,
                          ),
                      ],
                    ),
                  ),
                ),

                // 3. Persistent Morphing Expanding Player Sheet
                ExpandingPlayerSheet(
                  isHome: isHome,
                  useRail: false,
                ),
              ],
            ),
      floatingActionButton: kDebugMode && sheetController.isCollapsed
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
    final banners =
        ref.watch(bannersProvider).valueOrNull ?? const <AppBanner>[];
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
