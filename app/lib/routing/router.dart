import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core_mock/dev_env.dart';
import '../features/album/album_screen.dart';
import '../features/artist/artist_screen.dart';
import '../features/dev/component_gallery.dart';
import '../features/diagnostics/diagnostics_screen.dart';
import '../features/equalizer/autoeq_sheet.dart';
import '../features/equalizer/equalizer_screen.dart';
import '../features/home/home_screen.dart';
import '../features/library/library_screen.dart';
import '../features/now_playing/now_playing_screen.dart';
import '../features/onboarding/onboarding_screen.dart';
import '../features/output/output_screen.dart';
import '../features/playlists/playlist_screen.dart';
import '../features/queue/queue_screen.dart';
import '../features/safety/safety_check_screen.dart';
import '../features/search/search_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/shell/app_shell.dart';
import '../features/sources/sources_screen.dart';
import '../features/storage/storage_screen.dart';
import 'routes.dart';

/// The four tabs live inside [AppShell] so the mini player stays docked.
/// Everything else is a full-screen push.
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
          GoRoute(
            path: Routes.library,
            pageBuilder: (c, s) =>
                const NoTransitionPage(child: LibraryScreen()),
          ),
          GoRoute(
            path: Routes.search,
            pageBuilder: (c, s) =>
                const NoTransitionPage(child: SearchScreen()),
          ),
          GoRoute(
            path: Routes.sources,
            pageBuilder: (c, s) =>
                const NoTransitionPage(child: SourcesScreen()),
          ),
        ],
      ),
      GoRoute(
        path: Routes.nowPlaying,
        builder: (c, s) => const NowPlayingScreen(),
      ),
      GoRoute(path: Routes.queue, builder: (c, s) => const QueueScreen()),
      GoRoute(
        path: '/album/:id',
        builder: (c, s) => AlbumScreen(albumId: s.pathParameters['id']!),
      ),
      GoRoute(
        path: '/artist/:id',
        builder: (c, s) => ArtistScreen(artistId: s.pathParameters['id']!),
      ),
      GoRoute(
        path: '/playlist/:id',
        builder: (c, s) => PlaylistScreen(playlistId: s.pathParameters['id']!),
      ),
      GoRoute(
        path: Routes.equalizer,
        builder: (c, s) => const EqualizerScreen(),
      ),
      GoRoute(path: Routes.autoEq, builder: (c, s) => const AutoEqScreen()),
      GoRoute(path: Routes.output, builder: (c, s) => const OutputScreen()),
      GoRoute(
        path: Routes.safety,
        builder: (c, s) => const SafetyCheckScreen(),
      ),
      GoRoute(
        path: Routes.onboarding,
        builder: (c, s) => const OnboardingScreen(),
      ),
      GoRoute(path: Routes.storage, builder: (c, s) => const StorageScreen()),
      GoRoute(
        path: Routes.settings,
        builder: (c, s) => const SettingsScreen(),
      ),
      GoRoute(
        path: Routes.diagnostics,
        builder: (c, s) => const DiagnosticsScreen(),
      ),
      GoRoute(
          path: Routes.gallery, builder: (c, s) => const ComponentGallery()),
    ],
  );
});
