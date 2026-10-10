import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:audio_service/audio_service.dart';
import 'core_live/audio_handler.dart';
import 'providers/core_providers.dart';
import 'app.dart';
import 'package:bitdrop/src/rust/frb_generated.dart';
import 'package:path_provider/path_provider.dart';

import 'features/storage/google_drive_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize the Rust FFI backend
  await RustLib.init();

  // Initialize the Android Background Audio Service
  final audioHandler = await AudioService.init(
    builder: () => BitDropAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.bitdrop.audio',
      androidNotificationChannelName: 'BitDrop Playback',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
    ),
  );
  
  // Stash the handler globally for the provider to pick up
  globalAudioHandler = audioHandler;

  // Cloud playback: the engine caches byte-range chunks on disk, so it needs a
  // writable directory, and a token source it can ask per track.
  globalDriveService = GoogleDriveService();

  final cacheRoot = await getApplicationCacheDirectory();
  final chunkCache = Directory('${cacheRoot.path}/cloud_chunks');
  await chunkCache.create(recursive: true);

  audioHandler
    ..cacheDir = chunkCache.path
    ..accessTokenProvider = globalDriveService.freshAccessToken;

  // Edge-to-edge with transparent system bars; the themes paint their own.
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: Colors.transparent,
  ));
  runApp(const ProviderScope(child: BitDropApp()));
}
