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

import 'core_live/cloud_library.dart';
import 'features/storage/google_drive_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize the Rust FFI backend
  await RustLib.init();

  // Initialize the Android Background Audio Service.
  //
  // This runs before runApp(), so anything thrown here means a black screen
  // and no clue why. Degrade instead: a bare handler still plays audio, it
  // just loses the lock-screen and notification controls.
  late final BitDropAudioHandler audioHandler;
  try {
    audioHandler = await AudioService.init(
      builder: BitDropAudioHandler.new,
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.bitdrop.audio',
        androidNotificationChannelName: 'BitDrop Playback',
        androidNotificationOngoing: true,
        androidStopForegroundOnPause: true,
      ),
    );
  } catch (e, st) {
    debugPrint('[bitdrop] background audio service unavailable: $e\n$st');
    audioHandler = BitDropAudioHandler();
  }
  
  // Stash the handler globally for the provider to pick up
  globalAudioHandler = audioHandler;

  // Cloud playback: the engine caches byte-range chunks on disk, so it needs a
  // writable directory, and a token source it can ask per track.
  globalDriveService = GoogleDriveService();

  final cacheRoot = await getApplicationCacheDirectory();
  final chunkCache = Directory('${cacheRoot.path}/cloud_chunks');
  await chunkCache.create(recursive: true);
  globalChunkCacheDir = chunkCache.path;
  globalArtworkCacheDir = '${cacheRoot.path}/tag_cache/artwork';

  audioHandler
    ..cacheDir = chunkCache.path
    ..accessTokenProvider = globalDriveService.freshAccessToken;

  // The index lives in support rather than cache: the OS may purge the cache
  // directory, and losing the library would force a full rescan of Drive.
  final supportDir = await getApplicationSupportDirectory();
  globalCloudLibrary = CloudLibrary(
    drive: globalDriveService,
    dbPath: '${supportDir.path}/library.db',
    cacheDir: '${cacheRoot.path}/tag_cache',
  );

  // Edge-to-edge with transparent system bars; the themes paint their own.
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: Colors.transparent,
  ));
  runApp(const ProviderScope(child: BitDropApp()));
}
