import 'package:bitdrop/core_live/output_device.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('UsbAudioDevice Model', () {
    test('instantiates with expected properties', () {
      const dev = UsbAudioDevice(
        deviceId: 1001,
        deviceName: '/dev/bus/usb/001/002',
        productName: 'FiiO KA17',
        manufacturerName: 'FiiO',
        vendorId: 0x2972,
        productId: 0x0047,
        hasPermission: true,
      );

      expect(dev.deviceId, 1001);
      expect(dev.deviceName, '/dev/bus/usb/001/002');
      expect(dev.productName, 'FiiO KA17');
      expect(dev.manufacturerName, 'FiiO');
      expect(dev.vendorId, 0x2972);
      expect(dev.productId, 0x0047);
      expect(dev.hasPermission, isTrue);
    });

    test('fromMap parses map correctly and supplies defaults', () {
      final dev = UsbAudioDevice.fromMap(const {
        'deviceId': 2002,
        'deviceName': '/dev/bus/usb/001/003',
        'productName': 'DUNU Titan X DAC',
        'manufacturerName': 'DUNU',
        'vendorId': 0x0a12,
        'productId': 0x0001,
        'hasPermission': false,
      });

      expect(dev.deviceId, 2002);
      expect(dev.deviceName, '/dev/bus/usb/001/003');
      expect(dev.productName, 'DUNU Titan X DAC');
      expect(dev.manufacturerName, 'DUNU');
      expect(dev.vendorId, 0x0a12);
      expect(dev.productId, 0x0001);
      expect(dev.hasPermission, isFalse);

      final emptyDev = UsbAudioDevice.fromMap(const {});
      expect(emptyDev.deviceId, 0);
      expect(emptyDev.deviceName, '');
      expect(emptyDev.productName, 'USB Audio Device');
      expect(emptyDev.manufacturerName, 'Unknown');
      expect(emptyDev.vendorId, 0);
      expect(emptyDev.productId, 0);
      expect(emptyDev.hasPermission, isFalse);
    });

    test('value equality and hashCode behavior', () {
      const dev1 = UsbAudioDevice(
        deviceId: 10,
        deviceName: 'dev1',
        productName: 'DAC',
        manufacturerName: 'Brand',
        vendorId: 100,
        productId: 200,
        hasPermission: true,
      );

      const dev2 = UsbAudioDevice(
        deviceId: 10,
        deviceName: 'dev1_alias',
        productName: 'DAC',
        manufacturerName: 'Brand',
        vendorId: 100,
        productId: 200,
        hasPermission: true,
      );

      const dev3 = UsbAudioDevice(
        deviceId: 10,
        deviceName: 'dev1',
        productName: 'DAC',
        manufacturerName: 'Brand',
        vendorId: 100,
        productId: 200,
        hasPermission: false,
      );

      expect(dev1, equals(dev2));
      expect(dev1.hashCode, equals(dev2.hashCode));
      expect(dev1, isNot(equals(dev3)));
    });
  });

  group('OutputDeviceProbe USB Host Broker Channel', () {
    const channelName = 'com.bitdrop/audio_device';
    const channel = MethodChannel(channelName);
    late OutputDeviceProbe probe;
    final List<MethodCall> log = [];

    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      log.clear();

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        log.add(call);
        switch (call.method) {
          case 'listUsbAudioDevices':
            return [
              {
                'deviceId': 101,
                'deviceName': '/dev/bus/usb/001/005',
                'productName': 'DUNU Titan X',
                'manufacturerName': 'DUNU',
                'vendorId': 0x262a,
                'productId': 0x1921,
                'hasPermission': true,
              },
              {
                'deviceId': 102,
                'deviceName': '/dev/bus/usb/001/006',
                'productName': 'Generic UAC2 DAC',
                'manufacturerName': 'HiFi',
                'vendorId': 0x1234,
                'productId': 0x5678,
                'hasPermission': false,
              }
            ];
          case 'requestUsbPermission':
            final devId = (call.arguments as Map)['deviceId'] as int;
            return devId == 101;
          case 'openUsbDevice':
            final devId = (call.arguments as Map)['deviceId'] as int;
            if (devId == 101) {
              return {
                'fd': 42,
                'deviceId': 101,
                'vendorId': 0x262a,
                'productId': 0x1921,
                'productName': 'DUNU Titan X',
                'manufacturerName': 'DUNU',
              };
            }
            throw PlatformException(code: 'PERMISSION_DENIED', message: 'Not permitted');
          case 'closeUsbDevice':
            return true;
          default:
            return null;
        }
      });

      probe = OutputDeviceProbe(channel: channel, autoPoll: false);
    });

    tearDown(() {
      probe.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      debugDefaultTargetPlatformOverride = null;
    });

    test('listUsbAudioDevices queries channel and parses returned devices', () async {
      final devices = await probe.listUsbAudioDevices();

      expect(devices.length, 2);
      expect(devices[0].deviceId, 101);
      expect(devices[0].productName, 'DUNU Titan X');
      expect(devices[0].hasPermission, isTrue);
      expect(devices[1].deviceId, 102);
      expect(devices[1].hasPermission, isFalse);

      expect(log.any((call) => call.method == 'listUsbAudioDevices'), isTrue);
    });

    test('requestUsbPermission invokes channel with deviceId', () async {
      final granted = await probe.requestUsbPermission(101);
      expect(granted, isTrue);

      final denied = await probe.requestUsbPermission(999);
      expect(denied, isFalse);

      expect(log.any((call) => call.method == 'requestUsbPermission' && (call.arguments as Map)['deviceId'] == 101), isTrue);
    });

    test('openUsbDevice returns file descriptor map on success, null on error', () async {
      final result = await probe.openUsbDevice(101);
      expect(result, isNotNull);
      expect(result!['fd'], 42);
      expect(result['productName'], 'DUNU Titan X');

      final failed = await probe.openUsbDevice(999);
      expect(failed, isNull);
    });

    test('closeUsbDevice delegates to platform channel', () async {
      final ok = await probe.closeUsbDevice();
      expect(ok, isTrue);
      expect(log.any((call) => call.method == 'closeUsbDevice'), isTrue);
    });

    test('onUsbDeviceDetached callback triggers when host sends detachment message', () async {
      int? detachedId;
      probe.onUsbDeviceDetached = (devId) {
        detachedId = devId;
      };

      // Simulate native platform message arriving on channel handler
      final byteData = channel.codec.encodeMethodCall(
        const MethodCall('onUsbDeviceDetached', 101),
      );
      await ServicesBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
        channelName,
        byteData,
        (ByteData? _) {},
      );

      expect(detachedId, 101);
    });

    test('unsupported platform returns default safe values without invoking channel', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

      final list = await probe.listUsbAudioDevices();
      expect(list, isEmpty);

      final perm = await probe.requestUsbPermission(101);
      expect(perm, isFalse);

      final openRes = await probe.openUsbDevice(101);
      expect(openRes, isNull);

      final closed = await probe.closeUsbDevice();
      expect(closed, isFalse);
    });
  });
}
