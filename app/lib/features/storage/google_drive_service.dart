import 'dart:async';

import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;

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
  GoogleDriveService() {
    _googleSignIn.onCurrentUserChanged.listen((account) {
      _accountController.add(account);
      if (account == null) {
        _driveApi = null;
      } else {
        unawaited(_initDriveApi());
      }
    });
    // Restores a previous session without showing UI.
    unawaited(_googleSignIn.signInSilently());
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

  final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: [drive.DriveApi.driveReadonlyScope],
  );

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

  Future<bool> signIn() async {
    try {
      final account = await _googleSignIn.signIn();
      if (account == null) return false; // user dismissed the picker
      await _initDriveApi();
      return _driveApi != null;
    } catch (e) {
      debugPrint('[drive] sign-in failed: $e');
      return false;
    }
  }

  Future<void> signOut() async {
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

  /// Top-level folders, for the onboarding folder picker.
  Future<List<drive.File>> listRootFolders() async {
    final children = await listChildren('root');
    return children.where((f) => f.mimeType == _folderMime).toList();
  }

  void dispose() {
    unawaited(_accountController.close());
  }
}
