import '../src/rust/api/audio_engine.dart' as rust;

/// Native transport boundary used by the queue coordinator.
class PlaybackEngine {
  Stream<rust.EngineEvent> events() => rust.engineEventsStream();
  int get position => rust.engineGetPosition();
  bool get isPlaying => rust.engineIsPlaying();
  rust.EngineBufferState get buffer => rust.engineBufferState();
  void play(String path) => rust.enginePlay(path: path);
  void stage(String path) => rust.engineSetNextTrack(path: path);
  void clearNext() => rust.engineClearNext();
  void resume() => rust.engineResume();
  void pause() => rust.enginePause();
  void stop() => rust.engineStop();
  void seek(int milliseconds) => rust.engineSeek(positionMs: milliseconds);
  void supplyToken(BigInt requestId, String? token) =>
      rust.engineSupplyToken(requestId: requestId, token: token);

  void playCloud(
          {required String fileId,
          required String url,
          required String authToken,
          required BigInt totalSize,
          required String cacheDir,
          required String ext}) =>
      rust.enginePlayCloud(
          fileId: fileId,
          url: url,
          authToken: authToken,
          totalSize: totalSize,
          cacheDir: cacheDir,
          ext: ext);

  void stageCloud(
          {required String fileId,
          required String url,
          required String authToken,
          required BigInt totalSize,
          required String cacheDir,
          required String ext}) =>
      rust.engineSetNextCloud(
          fileId: fileId,
          url: url,
          authToken: authToken,
          totalSize: totalSize,
          cacheDir: cacheDir,
          ext: ext);
}
