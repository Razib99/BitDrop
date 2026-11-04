import 'dart:io';
import 'package:bitdrop/core_api/enums.dart';
import 'package:bitdrop/core_live/cloud_library.dart';
import 'package:bitdrop/features/storage/google_drive_service.dart';
import 'package:bitdrop/src/rust/api/cloud_library.dart' as rust;
import 'package:bitdrop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:googleapis/drive/v3.dart' as drive;

class FailingDrive extends GoogleDriveService {
  int foldersListed = 0;
  @override
  bool get isSignedIn => true;
  @override
  Future<List<drive.File>> listChildren(String folderId) async {
    foldersListed++;
    if (folderId == 'root-folder') {
      return [
        drive.File(
            id: 'child-folder',
            name: 'Child',
            mimeType: 'application/vnd.google-apps.folder')
      ];
    }
    throw const SocketException('Connection interrupted');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await RustLib.init(
        externalLibrary: ExternalLibrary.open(
            '${Directory.current.path}/rust/target/debug/librust_lib_bitdrop.so'));
  });
  test('a failed folder walk preserves indexed files and reports an error',
      () async {
    final dir = Directory.systemTemp.createTempSync('bitdrop-scan-failure-');
    final service = FailingDrive();
    final library = CloudLibrary(
        drive: service, dbPath: '${dir.path}/library.db', cacheDir: dir.path);
    try {
      await library.open();
      await rust.cloudLibraryAddFiles(
          fileIds: ['existing'],
          names: ['Existing.flac'],
          folderPaths: ['Music / Child'],
          sizes: Uint64List.fromList([1024]));
      await library.scan(only: [
        const DriveFolder(id: 'root-folder', name: 'Music', path: 'Music')
      ]);
      expect(service.foldersListed, 2);
      expect((await rust.cloudLibraryTracks()).map((t) => t.fileId),
          contains('existing'));
      expect((await library.status.first).phase, SyncPhase.error);
      expect(library.isScanning, isFalse);
    } finally {
      library.dispose();
      dir.deleteSync(recursive: true);
    }
  });
}
