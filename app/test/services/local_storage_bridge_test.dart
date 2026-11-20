import 'package:bitdrop/services/local_storage_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.bitdrop/local_storage');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('LocalStorageBridge permission tests', () {
    test('getAudioPermissionStatus parses granted Android 13+ permission map',
        () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        expect(call.method, equals('getAudioPermissionStatus'));
        return {
          'granted': true,
          'permanentlyDenied': false,
          'permission': 'android.permission.READ_MEDIA_AUDIO',
          'apiLevel': 34,
        };
      });

      final bridge = LocalStorageBridge();
      final status = await bridge.getAudioPermissionStatus();

      expect(status.granted, isTrue);
      expect(status.permanentlyDenied, isFalse);
      expect(status.permission, equals('android.permission.READ_MEDIA_AUDIO'));
      expect(status.apiLevel, equals(34));
    });

    test('requestAudioPermission surfaces permanentlyDenied status', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        expect(call.method, equals('requestAudioPermission'));
        return {
          'granted': false,
          'permanentlyDenied': true,
          'permission': 'android.permission.READ_MEDIA_AUDIO',
          'apiLevel': 35,
        };
      });

      final bridge = LocalStorageBridge();
      final status = await bridge.requestAudioPermission();

      expect(status.granted, isFalse);
      expect(status.permanentlyDenied, isTrue);
      expect(status.apiLevel, equals(35));
    });

    test('openAppSettings delegates to native channel', () async {
      var opened = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'openAppSettings') {
          opened = true;
          return true;
        }
        return null;
      });

      final bridge = LocalStorageBridge();
      expect(await bridge.openAppSettings(), isTrue);
      expect(opened, isTrue);
    });

    test('handles missing plugin gracefully without throwing', () async {
      final bridge = LocalStorageBridge();
      final status = await bridge.getAudioPermissionStatus();
      expect(status.granted, isFalse);
      expect(await bridge.openAppSettings(), isFalse);
    });
  });
}
