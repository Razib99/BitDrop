import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/dev/component_gallery.dart';
import '../features/home/home_screen.dart';
import '../features/shell/app_shell.dart';
import 'routes.dart';

final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: Routes.home,
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
        path: Routes.gallery,
        builder: (c, s) => const ComponentGallery(),
      ),
    ],
  );
});
