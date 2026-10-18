import 'dart:async';

import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;

/// Why a connection attempt ended the way it did.
///
/// "Failed" and "not possible here" are different things and must read
/// differently: telling a desktop user their credentials are wrong when the
/// platform has no sign-in plugin at all would send them hunting a bug that
/// does not exist.
enum DriveConnectResult {
  connected,

  /// The user dismissed the account picker.
  cancelled,

  /// google_sign_in has no implementation for this platform. Linux and
  /// Windows ship no plugin, so the call would throw MissingPluginException.
  unsupportedPlatform,

  /// Reached Google and was refused, or the network failed.
  failed,
}

extension DriveConnectResultMessage on DriveConnectResult {
  /// What to tell the user. Null when there is nothing to say, i.e. they
  /// connected, or chose to back out themselves.
  String? get message => switch (this) {
        DriveConnectResult.connected => null,
        DriveConnectResult.cancelled => null,
        DriveConnectResult.unsupportedPlatform =>
          'Google Drive sign-in is not available on this platform. '
              'Use the Android or iOS build to connect your cloud library.',
        DriveConnectResult.failed =>
          'Could not connect to Google Drive. If you saw an "unverified app" '
              'warning, choose Advanced and continue.',
      };
}

/// One audio file found in the user's Drive.
///
/// This is the hand-off point to the Rust engine: [id] and [sizeBytes] are
/// everything `engine_play_cloud` needs besides a token, because the download
/// URL is derived from the id.
@immutable
class DriveAudioFile {
  const DriveAudioFile({
    required this.id,
    required this.name,
    required this.sizeBytes,
    required this.folderPath,
    this.mimeType,
    this.modifiedTime,
  });

  final String id;
  final String name;
  final int sizeBytes;

  /// Human-readable trail, e.g. `Music / Hi-Res / Glass Harbor`.
  final String folderPath;
  final String? mimeType;
  final DateTime? modifiedTime;

  /// Lowercase extension without the dot, used as the decoder's format hint.
  String get extension {
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return '';
    return name.substring(dot + 1).toLowerCase();
  }

  /// The endpoint `RangeFetcher` fetches byte ranges from. It honours
  /// `Range` headers and takes the access token as a bearer header.
  String get downloadUrl =>
      'https://www.googleapis.com/drive/v3/files/$id?alt=media';
}

/// A Drive folder, for the picker.
@immutable
class DriveFolder {
  const DriveFolder({
    required this.id,
    required this.name,
    this.path = '',
  });

  final String id;
  final String name;

  /// Display trail, e.g. `My Drive / Music`.
  final String path;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'path': path};

  static DriveFolder fromJson(Map<String, dynamic> j) => DriveFolder(
        id: j['id'] as String,
        name: j['name'] as String,
        path: (j['path'] as String?) ?? '',
      );

  @override
  bool operator ==(Object other) => other is DriveFolder && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// Progress while walking the Drive tree.
@immutable
class DriveScanProgress {
  const DriveScanProgress({
    required this.filesFound,
    required this.foldersVisited,
    required this.currentFolder,
  });

  final int filesFound;
  final int foldersVisited;
  final String currentFolder;
}

/// Google Drive access: sign-in, token supply and library scanning.
///
/// BitDrop has no server, so everything here runs on the device against the
/// user's own Drive with a read-only scope. Nothing is uploaded and nothing is
/// written back.
class GoogleDriveService {
  GoogleDriveService({String? customClientId, bool useFullScope = false})
      : _customClientId = customClientId,
        _useFullScope = useFullScope {
    if (!isPlatformSupported) {
      debugPrint('[drive] Google Sign-In is unavailable on this platform; '
          'cloud features are disabled.');
      return;
    }
    _initGoogleSignIn();
  }

  /// Extensions the Rust engine can actually decode. Anything else in the
  /// user's folders is ignored by the scanner rather than listed and then
  /// failing at play time.
  static const supportedExtensions = {
    'flac',
    'alac',
    'wav',
    'wave',
    'aif',
    'aiff',
    'mp3',
    'm4a',
    'aac',
    'ogg',
  };

  static const _folderMime = 'application/vnd.google-apps.folder';

  /// Whether Google Sign-In exists on this platform at all.
  ///
  /// google_sign_in resolves implementations for Android, iOS and web only.
  /// On Linux and Windows the plugin list is empty, so every call throws.
  /// Checked up front so the UI can explain rather than fail.
  static bool get isPlatformSupported =>
      kIsWeb ||
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  /// Default non-sensitive scope eliminating CASA Tier-2 audit fees ($600-$3,000/yr)
  /// and 7-day token expirations under Google Cloud policies (F-04).
  static const String defaultScope = drive.DriveApi.driveFileScope;
  static const String fullReadonlyScope = drive.DriveApi.driveReadonlyScope;

  String? _customClientId;
  bool _useFullScope = false;

  String? get customClientId => _customClientId;
  bool get useFullScope => _useFullScope;

  late GoogleSignIn _googleSignIn;
  StreamSubscription<GoogleSignInAccount?>? _sub;

  void _initGoogleSignIn() {
    _sub?.cancel();
    _googleSignIn = GoogleSignIn(
      clientId: _customClientId,
      scopes: [
        _useFullScope
            ? drive.DriveApi.driveReadonlyScope
            : drive.DriveApi.driveFileScope,
      ],
    );
    _sub = _googleSignIn.onCurrentUserChanged.listen((account) {
      _accountController.add(account);
      if (account == null) {
        _driveApi = null;
      } else {
        unawaited(_initDriveApi());
      }
    });
    if (isPlatformSupported) {
      unawaited(_googleSignIn.signInSilently());
    }
  }

  /// Power-user configuration: switch between default `drive.file` and custom GCP OAuth Client ID (F-04).
  Future<void> configureAuth(
      {String? customClientId, bool useFullScope = false}) async {
    _customClientId = (customClientId != null && customClientId.trim().isNotEmpty)
        ? customClientId.trim()
        : null;
    _useFullScope = useFullScope;
    await signOut();
    _initGoogleSignIn();
  }

  drive.DriveApi? _driveApi;

  final StreamController<GoogleSignInAccount?> _accountController =
      StreamController<GoogleSignInAccount?>.broadcast();

  Stream<GoogleSignInAccount?> get accountStream => _accountController.stream;
  GoogleSignInAccount? get currentUser => _googleSignIn.currentUser;
  bool get isSignedIn => _driveApi != null;

  Future<void> _initDriveApi() async {
    try {
      final client = await _googleSignIn.authenticatedClient();
      if (client != null) _driveApi = drive.DriveApi(client);
    } catch (e) {
      debugPrint('[drive] could not initialise Drive API: $e');
    }
  }

  Future<DriveConnectResult> signIn() async {
    if (!isPlatformSupported) return DriveConnectResult.unsupportedPlatform;

    try {
      final account = await _googleSignIn.signIn();
      if (account == null) return DriveConnectResult.cancelled;
      await _initDriveApi();
      return _driveApi != null
          ? DriveConnectResult.connected
          : DriveConnectResult.failed;
    } on MissingPluginException {
      // Belt and braces: the platform check above should already have caught
      // this, but a partial plugin registration would land here.
      return DriveConnectResult.unsupportedPlatform;
    } catch (e) {
      debugPrint('[drive] sign-in failed: $e');
      return DriveConnectResult.failed;
    }
  }

  Future<void> signOut() async {
    if (!isPlatformSupported) return;
    try {
      await _googleSignIn.signOut();
      _driveApi = null;
    } catch (e) {
      debugPrint('[drive] sign-out failed: $e');
    }
  }

  /// A currently-valid OAuth access token, or null if signed out.
  ///
  /// Access tokens last about an hour, so this is fetched per track rather
  /// than cached: a long listening session would otherwise hand the engine a
  /// token that expires mid-album. A silent re-auth is attempted first, which
  /// also covers the roughly weekly re-consent that Google's testing mode
  /// forces.
  Future<String?> freshAccessToken() async {
    if (!isPlatformSupported) return null;
    try {
      var account = _googleSignIn.currentUser;
      account ??= await _googleSignIn.signInSilently();
      if (account == null) return null;

      final auth = await account.authentication;
      return auth.accessToken;
    } catch (e) {
      debugPrint('[drive] could not obtain access token: $e');
      return null;
    }
  }

  /// Lists one folder's children, following pagination to the end.
  ///
  /// Drive returns at most 1000 entries per page, and a music folder can
  /// easily exceed that, so stopping at the first page would silently lose
  /// tracks.
  Future<List<drive.File>> listChildren(String folderId) async {
    final api = _driveApi;
    if (api == null) {
      debugPrint('[drive] not signed in');
      return const [];
    }

    final out = <drive.File>[];
    String? pageToken;

    do {
      try {
        final page = await api.files.list(
          q: "'$folderId' in parents and trashed = false",
          spaces: 'drive',
          $fields:
              'nextPageToken, files(id, name, mimeType, size, modifiedTime)',
          pageSize: 1000,
          pageToken: pageToken,
          orderBy: 'folder,name',
        );
        out.addAll(page.files ?? const []);
        pageToken = page.nextPageToken;
      } catch (e) {
        debugPrint('[drive] listing $folderId failed: $e');
        break;
      }
    } while (pageToken != null);

    return out;
  }

  /// Walks [rootFolderId] and everything under it, yielding audio files.
  ///
  /// Breadth-first so the shallow, most-likely-wanted folders surface first,
  /// which lets the library be browsable long before the walk finishes.
  Stream<DriveAudioFile> scanFolder(
    String rootFolderId, {
    String rootName = 'Drive',
    void Function(DriveScanProgress)? onProgress,
  }) async* {
    final queue = <({String id, String path})>[
      (id: rootFolderId, path: rootName),
    ];

    // Drive lets a file live in several folders, so a plain walk can revisit
    // the same subtree and emit duplicates.
    final seenFolders = <String>{rootFolderId};
    var filesFound = 0;
    var foldersVisited = 0;

    while (queue.isNotEmpty) {
      final folder = queue.removeAt(0);
      final children = await listChildren(folder.id);
      foldersVisited++;

      for (final child in children) {
        final id = child.id;
        final name = child.name;
        if (id == null || name == null) continue;

        if (child.mimeType == _folderMime) {
          if (seenFolders.add(id)) {
            queue.add((id: id, path: '${folder.path} / $name'));
          }
          continue;
        }

        final file = DriveAudioFile(
          id: id,
          name: name,
          sizeBytes: int.tryParse(child.size ?? '') ?? 0,
          folderPath: folder.path,
          mimeType: child.mimeType,
          modifiedTime: child.modifiedTime,
        );

        // Filter on extension, not mime type: Drive frequently reports
        // audio/x-flac, application/octet-stream or nothing at all for the
        // same file depending on how it was uploaded.
        if (!supportedExtensions.contains(file.extension)) continue;
        if (file.sizeBytes <= 0) continue;

        filesFound++;
        onProgress?.call(DriveScanProgress(
          filesFound: filesFound,
          foldersVisited: foldersVisited,
          currentFolder: folder.path,
        ));
        yield file;
      }
    }
  }

  /// Convenience wrapper that scans the whole Drive.
  Stream<DriveAudioFile> scanEntireDrive({
    void Function(DriveScanProgress)? onProgress,
  }) =>
      scanFolder('root', onProgress: onProgress);

  /// Folders directly inside [parentId]. Use `'root'` for the top level.
  ///
  /// Only folders are returned: the picker is for choosing where to look, and
  /// listing thousands of audio files inside it would make it unusable.
  Future<List<DriveFolder>> listFolders(
    String parentId, {
    String parentPath = 'My Drive',
  }) async {
    final api = _driveApi;
    if (api == null) return const [];

    final out = <DriveFolder>[];
    String? pageToken;
    do {
      try {
        final page = await api.files.list(
          q: "'$parentId' in parents and trashed = false and "
              "mimeType = '$_folderMime'",
          spaces: 'drive',
          $fields: 'nextPageToken, files(id, name)',
          pageSize: 200,
          pageToken: pageToken,
          orderBy: 'name',
        );
        for (final f in page.files ?? const <drive.File>[]) {
          final id = f.id;
          final name = f.name;
          if (id == null || name == null) continue;
          out.add(DriveFolder(
            id: id,
            name: name,
            path: '$parentPath / $name',
          ));
        }
        pageToken = page.nextPageToken;
      } catch (e) {
        debugPrint('[drive] listing folders in $parentId failed: $e');
        break;
      }
    } while (pageToken != null);

    return out;
  }

  /// Top-level folders, for the onboarding folder picker.
  Future<List<drive.File>> listRootFolders() async {
    final children = await listChildren('root');
    return children.where((f) => f.mimeType == _folderMime).toList();
  }

  void dispose() {
    unawaited(_accountController.close());
  }
}
