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
import '../../widgets/bottom_nav_bar.dart';
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
    final shortestSide = MediaQuery.sizeOf(context).shortestSide;
    final useRail = width >= 840 && shortestSide >= 600;
    final l = context.l10n;

    final destinations = <BitDropNavDestination>[
      BitDropNavDestination(
        path: Routes.home,
        icon: Icons.home_outlined,
        label: l.navHome,
      ),
      BitDropNavDestination(
        path: Routes.library,
        icon: Icons.library_music_outlined,
        label: l.navLibrary,
      ),
      BitDropNavDestination(
        path: Routes.search,
        icon: Icons.search_rounded,
        label: l.navSearch,
      ),
      BitDropNavDestination(
        path: Routes.sources,
        icon: Icons.cloud_outlined,
        label: l.navSources,
      ),
    ];

    final location = GoRouterState.of(context).uri.path;
    final isHome = location == Routes.home || location == '/';
    var index = destinations.indexWhere((d) => location.startsWith(d.path));
    if (index < 0) index = 0;

    final sheetController = ref.watch(playerSheetControllerProvider);
    final sheetProgress = sheetController.progress;

    final hasNowPlaying = ref.watch(nowPlayingProvider).valueOrNull != null;
    final showMiniPlayer = hasNowPlaying && !isHome;

    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final navBarHeight = 64.0 + bottomInset;

    final body = Column(
      children: [
        const _BannerStack(),
        Expanded(
          child: AnimatedPadding(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
            padding: EdgeInsets.only(
              bottom: useRail
                  ? 0.0
                  : (showMiniPlayer
                      ? (navBarHeight + Sizes.miniPlayerHeight)
                      : navBarHeight),
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
              fit: StackFit.expand,
              children: [
                // 1. Full page content (banner stack + child)
                SafeArea(
                  bottom: false,
                  child: body,
                ),

                // 2. Navigation bar, translating down off screen as sheet expands
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Transform.translate(
                    offset: Offset(0, sheetProgress * 120.0),
                    child: MediaQuery.removePadding(
                      context: context,
                      removeTop: true,
                      child: BitDropBottomNavBar(
                        selectedIndex: index,
                        onDestinationSelected: (i) {
                          if (destinations[i].path == Routes.library) {
                            ref.read(libraryTabProvider.notifier).state =
                                LibraryTab.tracks;
                          }
                          context.go(destinations[i].path);
                        },
                        destinations: destinations,
                      ),
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

class _Rail extends StatelessWidget {
  const _Rail({
    required this.destinations,
    required this.index,
    required this.onSelect,
  });

  final List<BitDropNavDestination> destinations;
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
              selectedIcon: Icon(d.icon),
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
