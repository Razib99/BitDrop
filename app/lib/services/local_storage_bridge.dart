import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// A discovered local directory on the user's device containing or intended for audio.
@immutable
class DiscoveredMusicDirectory {
  const DiscoveredMusicDirectory({
    required this.path,
    required this.label,
    this.isRemovable = false,
    this.audioFileCount = 0,
  });

  final String path;
  final String label;
  final bool isRemovable;
  final int audioFileCount;

  factory DiscoveredMusicDirectory.fromMap(Map<String, dynamic> map) =>
      DiscoveredMusicDirectory(
        path: (map['path'] as String? ?? '').trim(),
        label: (map['label'] as String? ?? '').trim(),
        isRemovable: map['isRemovable'] as bool? ?? false,
        audioFileCount: (map['audioFileCount'] as num?)?.toInt() ?? 0,
      );

  @override
  bool operator ==(Object other) =>
      other is DiscoveredMusicDirectory &&
      other.path == path &&
      other.label == label &&
      other.isRemovable == isRemovable &&
      other.audioFileCount == audioFileCount;

  @override
  int get hashCode => Object.hash(path, label, isRemovable, audioFileCount);
}

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

  /// Discovers standard device music directories (`Music`, `Download`,
  /// `Audiobooks`, SD card roots) and custom MediaStore audio roots on Android,
  /// or standard home audio directories on desktop platforms.
  Future<List<DiscoveredMusicDirectory>> discoverMusicDirectories() async {
    if (kIsWeb) return const [];
    if (_isAndroid) {
      try {
        final rawList = await _channel.invokeListMethod<Map<dynamic, dynamic>>(
          'discoverMusicDirectories',
        );
        if (rawList == null) return const [];
        final seen = <String>{};
        final out = <DiscoveredMusicDirectory>[];
        for (final entry in rawList) {
          final dir = DiscoveredMusicDirectory.fromMap(
            Map<String, dynamic>.from(entry),
          );
          if (dir.path.isNotEmpty && seen.add(dir.path)) {
            out.add(dir);
          }
        }
        return out;
      } catch (e) {
        debugPrint('[storage-bridge] discoverMusicDirectories failed: $e');
        return const [];
      }
    }

    if (defaultTargetPlatform == TargetPlatform.iOS) {
      try {
        final docs = await getApplicationDocumentsDirectory();
        if (docs.existsSync()) {
          return [
            DiscoveredMusicDirectory(path: docs.path, label: 'On My iPhone'),
          ];
        }
      } catch (e) {
        debugPrint('[storage-bridge] iOS documents dir probe failed: $e');
      }
      return const [];
    }

    // Desktop fallback: probe standard user Music / Downloads directories.
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';
    if (home.isEmpty) return const [];
    final out = <DiscoveredMusicDirectory>[];
    for (final name in const ['Music', 'Downloads']) {
      final dir = Directory('$home${Platform.pathSeparator}$name');
      if (dir.existsSync()) {
        out.add(DiscoveredMusicDirectory(path: dir.path, label: name));
      }
    }
    return out;
  }
}
