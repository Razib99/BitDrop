import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';

class GoogleDriveService {
  final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: [
      drive.DriveApi.driveReadonlyScope,
    ],
  );

  drive.DriveApi? _driveApi;

  // Stream for UI reactive updates
  final StreamController<GoogleSignInAccount?> _accountController =
      StreamController<GoogleSignInAccount?>.broadcast();

  Stream<GoogleSignInAccount?> get accountStream => _accountController.stream;
  GoogleSignInAccount? get currentUser => _googleSignIn.currentUser;

  GoogleDriveService() {
    _googleSignIn.onCurrentUserChanged.listen((GoogleSignInAccount? account) {
      _accountController.add(account);
      if (account != null) {
        _initDriveApi();
      } else {
        _driveApi = null;
      }
    });
    // Attempt to sign in silently if previously authenticated
    _googleSignIn.signInSilently();
  }

  Future<void> _initDriveApi() async {
    try {
      final authClient = await _googleSignIn.authenticatedClient();
      if (authClient != null) {
        _driveApi = drive.DriveApi(authClient);
        debugPrint("Drive API initialized successfully.");
      }
    } catch (e) {
      debugPrint("Failed to initialize Drive API: $e");
    }
  }

  Future<void> signIn() async {
    try {
      await _googleSignIn.signIn();
    } catch (error) {
      debugPrint('Google Sign-In Error: $error');
      // Even if login fails (e.g., no client ID configured yet), we catch it gracefully.
    }
  }

  Future<void> signOut() async {
    try {
      await _googleSignIn.signOut();
    } catch (error) {
      debugPrint('Google Sign-Out Error: $error');
    }
  }

  // Example API method for testing
  Future<List<drive.File>?> listAudioFiles() async {
    if (_driveApi == null) {
      debugPrint("Drive API is not initialized. Please sign in.");
      return null;
    }

    try {
      // Query for FLAC and MP3 files
      final fileList = await _driveApi!.files.list(
        q: "mimeType='audio/flac' or mimeType='audio/mpeg'",
        spaces: 'drive',
        $fields: 'files(id, name, mimeType, size)',
      );
      return fileList.files;
    } catch (e) {
      debugPrint("Failed to list files: $e");
      return null;
    }
  }

  void dispose() {
    _accountController.close();
  }
}
