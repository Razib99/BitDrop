import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core_api/enums.dart';
import '../core_api/models.dart';

/// Reads the real output device from Android's AudioManager.
///
/// BitDrop's premise is never claiming a quality it has not verified, so this
/// reports only what the platform states. A capability the device does not
/// advertise comes back empty and is shown as unknown, never guessed.
class OutputDeviceProbe {
  static const _channel = MethodChannel('com.bitdrop/audio_device');

  /// Polled rather than pushed: AudioManager has no callback that covers
  /// every routing change, and a DAC being plugged in must be noticed.
  Timer? _timer;
  final _controller = StreamController<OutputDevice?>.broadcast();
  OutputDevice? _last;

  Stream<OutputDevice?> get stream async* {
    yield _last;
    yield* _controller.stream;
  }

  OutputDevice? get current => _last;

  void start() {
    _timer ??= Timer.periodic(const Duration(seconds: 2), (_) => _poll());
    unawaited(_poll());
  }

  Future<void> _poll() async {
    final device = await read();
    // Only emit on a real change, so the signal path does not churn twice a
    // second for nothing.
    if (device?.id != _last?.id || device?.name != _last?.name) {
      _last = device;
      if (!_controller.isClosed) _controller.add(device);
    }
  }

  Future<OutputDevice?> read() async {
    if (!_supported) return null;
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>(
        'currentOutput',
      );
      if (raw == null || raw['available'] != true) return null;

      final type = switch (raw['type'] as String? ?? 'unknown') {
        'usb' => DeviceType.usb,
        'wired' => DeviceType.wiredAnalog,
        'bluetooth' => DeviceType.bluetooth,
        'speaker' => DeviceType.phoneSpeaker,
        _ => DeviceType.unknown,
      };

      final rates = (raw['sampleRates'] as List?)?.cast<int>() ?? const <int>[];
      final encodings =
          (raw['encodings'] as List?)?.cast<int>() ?? const <int>[];

      final name = (raw['name'] as String? ?? '').trim();

      return OutputDevice(
        id: 'android-${type.name}-$name',
        name: name.isEmpty ? _fallbackName(type) : name,
        type: type,
        supportedRates: rates..sort(),
        bitDepths: _depthsFrom(encodings),
        // Android exposes no way to ask whether a USB DAC has its own volume
        // control, so this stays unknown until the safety check establishes
        // it. Claiming either way would be a guess.
        hardwareVolume: type == DeviceType.phoneSpeaker
            ? HardwareVolume.yes
            : HardwareVolume.unknown,
        maxTier: _maxTierFor(type),
        connectionLabel: switch (type) {
          DeviceType.usb => 'USB-C',
          DeviceType.bluetooth => 'Bluetooth',
          DeviceType.wiredAnalog => '3.5 mm',
          _ => null,
        },
      );
    } catch (e) {
      debugPrint('[output] could not read the device: $e');
      return null;
    }
  }

  static bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static String _fallbackName(DeviceType type) => switch (type) {
        DeviceType.usb => 'USB audio device',
        DeviceType.bluetooth => 'Bluetooth audio',
        DeviceType.wiredAnalog => 'Wired headphones',
        DeviceType.phoneSpeaker => 'Phone speaker',
        DeviceType.unknown => 'Unknown output',
      };

  /// AudioFormat encoding constants, mapped to bit depths.
  static List<int> _depthsFrom(List<int> encodings) {
    const pcm16 = 2;
    const pcm8 = 3;
    const pcmFloat = 4;
    const pcm24Packed = 21;
    const pcm32 = 22;

    final out = <int>{};
    for (final e in encodings) {
      switch (e) {
        case pcm8:
          out.add(8);
        case pcm16:
          out.add(16);
        case pcm24Packed:
          out.add(24);
        case pcm32:
        case pcmFloat:
          out.add(32);
      }
    }
    final sorted = out.toList()..sort();
    return sorted;
  }

  /// The best this device could ever reach on this phone.
  ///
  /// Android 12 has no bit-perfect path at all: setPreferredMixerAttributes
  /// arrived in API 34. Reporting anything better here would be the exact
  /// dishonesty the app exists to avoid.
  static OutputTier _maxTierFor(DeviceType type) => switch (type) {
        // Bluetooth re-encodes with its own codec, so lossless is impossible
        // regardless of phone or Android version.
        DeviceType.bluetooth => OutputTier.resampled,
        DeviceType.phoneSpeaker => OutputTier.resampled,
        _ => OutputTier.nativeRate,
      };

  void dispose() {
    _timer?.cancel();
    unawaited(_controller.close());
  }
}
