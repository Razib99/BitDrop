import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Current Android runtime audio-storage permission state.
@immutable
class AudioStoragePermissionStatus {
  const AudioStoragePermissionStatus({
    required this.granted,
    this.permanentlyDenied = false,
    this.permission = '',
    this.apiLevel = 0,
  });

  final bool granted;
  final bool permanentlyDenied;
  final String permission;
  final int apiLevel;

  factory AudioStoragePermissionStatus.fromMap(Map<String, dynamic> map) =>
      AudioStoragePermissionStatus(
        granted: map['granted'] as bool? ?? false,
        permanentlyDenied: map['permanentlyDenied'] as bool? ?? false,
        permission: map['permission'] as String? ?? '',
        apiLevel: map['apiLevel'] as int? ?? 0,
      );

  static const AudioStoragePermissionStatus desktopGranted =
      AudioStoragePermissionStatus(
    granted: true,
    permanentlyDenied: false,
    permission: 'desktop',
    apiLevel: 0,
  );
}

/// Platform channel bridge for Android local audio storage permissions
/// and device music directory discovery.
class LocalStorageBridge {
  LocalStorageBridge({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(_channelName);

  static const String _channelName = 'com.bitdrop/local_storage';
  final MethodChannel _channel;

  static bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<AudioStoragePermissionStatus> getAudioPermissionStatus() async {
    if (!_isAndroid) {
      return AudioStoragePermissionStatus.desktopGranted;
    }
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>(
        'getAudioPermissionStatus',
      );
      if (raw == null) {
        return const AudioStoragePermissionStatus(granted: false);
      }
      return AudioStoragePermissionStatus.fromMap(raw);
    } catch (e) {
      debugPrint('[storage-bridge] getAudioPermissionStatus failed: $e');
      return const AudioStoragePermissionStatus(granted: false);
    }
  }

  Future<AudioStoragePermissionStatus> requestAudioPermission() async {
    if (!_isAndroid) {
      return AudioStoragePermissionStatus.desktopGranted;
    }
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>(
        'requestAudioPermission',
      );
      if (raw == null) {
        return const AudioStoragePermissionStatus(granted: false);
      }
      return AudioStoragePermissionStatus.fromMap(raw);
    } catch (e) {
      debugPrint('[storage-bridge] requestAudioPermission failed: $e');
      return const AudioStoragePermissionStatus(granted: false);
    }
  }

  Future<bool> openAppSettings() async {
    if (!_isAndroid) return false;
    try {
      final opened = await _channel.invokeMethod<bool>('openAppSettings');
      return opened ?? false;
    } catch (e) {
      debugPrint('[storage-bridge] openAppSettings failed: $e');
      return false;
    }
  }
}
