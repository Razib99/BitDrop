/// Route paths, in one place so widgets never spell a location twice.
abstract final class Routes {
  static const onboarding = '/onboarding';
  static const home = '/home';
  static const library = '/library';
  static const search = '/search';
  static const sources = '/sources';

  static const nowPlaying = '/now-playing';
  static const queue = '/queue';
  static const equalizer = '/equalizer';
  static const autoEq = '/equalizer/autoeq';
  static const output = '/output';
  static const safety = '/safety';
  static const storage = '/storage';
  static const settings = '/settings';
  static const diagnostics = '/diagnostics';
  static const playlists = '/playlists';
  static const gallery = '/dev/gallery';

  static String album(String id) => '/album/$id';
  static String artist(String id) => '/artist/$id';
  static String playlist(String id) => '/playlist/$id';
  static String folder(String? id) =>
      id == null ? '/folders' : '/folders?id=$id';
}
