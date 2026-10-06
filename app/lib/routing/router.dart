import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core_mock/dev_env.dart';
import '../features/album/album_screen.dart';
import '../features/artist/artist_screen.dart';
import '../features/dev/component_gallery.dart';
import '../features/home/home_screen.dart';
import '../features/library/library_screen.dart';
import '../features/now_playing/now_playing_screen.dart';
import '../features/playlists/playlist_screen.dart';
import '../features/queue/queue_screen.dart';
import '../features/search/search_screen.dart';
import '../features/shell/app_shell.dart';
import '../features/sources/sources_screen.dart';
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
        builder: (c, s) =>
            PlaylistScreen(playlistId: s.pathParameters['id']!),
      ),
      GoRoute(path: Routes.gallery, builder: (c, s) => const ComponentGallery()),
    ],
  );
});
