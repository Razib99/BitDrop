import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core_mock/dev_env.dart';
import '../features/dev/component_gallery.dart';
import '../features/home/home_screen.dart';
import '../features/now_playing/now_playing_screen.dart';
import '../features/queue/queue_screen.dart';
import '../features/shell/app_shell.dart';
import 'routes.dart';

/// Tab destinations live inside [AppShell]; everything else is a full-screen
/// push so the mini player gets out of the way.
final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: DevEnv.initialRoute ?? Routes.home,
    routes: [
      ShellRoute(
        builder: (context, state, child) => AppShell(child: child),
        routes: [
          GoRoute(
            path: Routes.home,
            pageBuilder: (c, s) => const NoTransitionPage(child: HomeScreen()),
          ),
        ],
      ),
      GoRoute(
        path: Routes.nowPlaying,
        builder: (c, s) => const NowPlayingScreen(),
      ),
      GoRoute(path: Routes.queue, builder: (c, s) => const QueueScreen()),
      GoRoute(path: Routes.gallery, builder: (c, s) => const ComponentGallery()),
    ],
  );
});
