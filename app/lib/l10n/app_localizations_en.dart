import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'BitDrop';

  @override
  String get tagline => 'Your lossless library. Your cloud. No compromises.';

  @override
  String get tierBitPerfect => 'Bit-perfect';

  @override
  String get tierNativeRate => 'Native rate';

  @override
  String get tierResampled => 'Resampled';

  @override
  String get tierUnknown => 'Unknown';

  @override
  String get dspShort => 'DSP';

  @override
  String get dspActive => 'DSP active';

  @override
  String get availCloudOnly => 'Streams from cloud';

  @override
  String availPartial(int percent) {
    return '$percent% cached';
  }

  @override
  String get availCached => 'Cached on device';

  @override
  String get availPinned => 'Pinned for offline';

  @override
  String get availDownloading => 'Downloading';

  @override
  String get availUnavailable => 'Not available offline';

  @override
  String get availUnsupported => 'Format not supported';

  @override
  String get availMissing => 'Removed from cloud';

  @override
  String get actionPlay => 'Play';

  @override
  String get actionPause => 'Pause';

  @override
  String get actionShuffle => 'Shuffle';

  @override
  String get actionNext => 'Next track';

  @override
  String get actionPrevious => 'Previous track';

  @override
  String get actionPlayNext => 'Play next';

  @override
  String get actionAddToQueue => 'Add to queue';

  @override
  String get actionAddToPlaylist => 'Add to playlist';

  @override
  String get actionPinOffline => 'Pin offline';

  @override
  String get actionUnpin => 'Unpin';

  @override
  String get actionClose => 'Close';

  @override
  String get actionDismiss => 'Dismiss';

  @override
  String get actionCancel => 'Cancel';

  @override
  String get actionDone => 'Done';

  @override
  String get actionBack => 'Back';

  @override
  String get actionRetry => 'Retry';

  @override
  String get actionReconnect => 'Reconnect';

  @override
  String get actionRescan => 'Rescan';

  @override
  String get actionRemove => 'Remove';

  @override
  String get actionSave => 'Save';

  @override
  String get actionApply => 'Apply';

  @override
  String get actionImport => 'Import';

  @override
  String get actionSkip => 'Skip';

  @override
  String get actionContinue => 'Continue';

  @override
  String get actionGetStarted => 'Get started';

  @override
  String get actionGoToAlbum => 'Go to album';

  @override
  String get actionGoToArtist => 'Go to artist';

  @override
  String get actionOpenFolder => 'Open folder';

  @override
  String get actionMore => 'More';

  @override
  String actionMoreFor(String title) {
    return 'More options for $title';
  }

  @override
  String get actionShuffleRemaining => 'Shuffle remaining';

  @override
  String get actionSaveAsPlaylist => 'Save as playlist';

  @override
  String get actionClear => 'Clear';

  @override
  String get actionUndo => 'Undo';

  @override
  String get actionSelectAll => 'Select all';

  @override
  String get repeatOff => 'Repeat off';

  @override
  String get repeatAll => 'Repeat all';

  @override
  String get repeatOne => 'Repeat one';

  @override
  String get shuffleOn => 'Shuffle on';

  @override
  String get shuffleOff => 'Shuffle off';

  @override
  String get seekPosition => 'Playback position';

  @override
  String get seekCached => 'Cached';

  @override
  String get seekWillStream => 'Will stream';

  @override
  String get seekRemainingHint => 'Remaining time. Tap for total duration.';

  @override
  String get seekTotalHint => 'Total duration. Tap for remaining time.';

  @override
  String get bufferingLabel => 'Buffering';

  @override
  String get bufferingSlow => 'Slow connection — building a bigger buffer';

  @override
  String bufferingDetail(String buffered, String target) {
    return 'Buffering · $buffered s of $target s';
  }

  @override
  String bufferAhead(String seconds) {
    return 'Buffer $seconds s';
  }

  @override
  String get navHome => 'Home';

  @override
  String get navLibrary => 'Library';

  @override
  String get navSearch => 'Search';

  @override
  String get navSources => 'Sources';

  @override
  String get navSettings => 'Settings';

  @override
  String get navQueue => 'Queue';

  @override
  String get navEq => 'EQ';

  @override
  String get navOutput => 'Output';

  @override
  String get navLyrics => 'Lyrics';

  @override
  String get signalPathTitle => 'Signal path';

  @override
  String get signalSource => 'Source';

  @override
  String get signalDecoder => 'Decoder';

  @override
  String get signalDsp => 'DSP';

  @override
  String get signalVolume => 'Volume';

  @override
  String get signalOutput => 'Output';

  @override
  String get signalDevice => 'Device';

  @override
  String get signalDspOff => 'Off — bypassed';

  @override
  String get signalDspOffDetail => 'True bypass: samples pass through untouched.';

  @override
  String get signalDspOnDetail => 'Processing changes the samples, so bit-perfect is not possible while this is on.';

  @override
  String get signalVolumeDac => 'DAC hardware';

  @override
  String get signalVolumeSoftware => 'Software, 24-bit dithered';

  @override
  String get signalVolumeSystem => 'System';

  @override
  String get signalVolumeDacDetail => 'BitDrop applies no digital gain. Use the volume keys.';

  @override
  String get signalVolumeSoftwareDetail => 'Digital gain is applied before output.';

  @override
  String get signalVolumeSystemDetail => 'Android controls the level.';

  @override
  String get signalOutputBitPerfect => 'Bit-perfect USB';

  @override
  String get signalOutputNative => 'Native rate';

  @override
  String signalOutputResampled(String rate) {
    return 'Android mixer → $rate';
  }

  @override
  String get signalFormatsMatch => 'Requested format matched exactly.';

  @override
  String signalFormatsDiffer(String requested, String actual) {
    return 'Requested $requested, got $actual.';
  }

  @override
  String get signalNoDevice => 'No device';

  @override
  String signalCachedStreaming(int percent, String rate) {
    return '$percent% cached · streaming $rate';
  }

  @override
  String signalCachedOffline(int percent) {
    return '$percent% cached · offline';
  }

  @override
  String signalSourceBitrate(String rate) {
    return '$rate source bitrate';
  }

  @override
  String signalDeviceCaps(String rates, String depths, String volume) {
    return 'Supports $rates kHz · $depths-bit · Hardware volume: $volume';
  }

  @override
  String get requestedVsActual => 'Requested vs. actual';

  @override
  String get colRequested => 'Requested';

  @override
  String get colActual => 'Actual';

  @override
  String get rowCodec => 'Codec';

  @override
  String get rowBitDepth => 'Bit depth';

  @override
  String get rowSampleRate => 'Sample rate';

  @override
  String get rowChannels => 'Channels';

  @override
  String get rowVolume => 'Volume';

  @override
  String get turnOffEqForBitPerfect => 'Turn off EQ for bit-perfect';

  @override
  String get runSafetyCheck => 'Run safety check';

  @override
  String get openDiagnostics => 'Open diagnostics';

  @override
  String get hwVolumeYes => 'Yes';

  @override
  String get hwVolumeNo => 'No';

  @override
  String get hwVolumeUnknown => 'Unknown';

  @override
  String get hardwareVolume => 'Hardware volume';

  @override
  String get sampleRatesUnit => 'Sample rates (kHz)';

  @override
  String get bitDepthsUnit => 'Bit depths (bit)';

  @override
  String get savedProfile => 'Saved profile';

  @override
  String unsupportedExplain(String reason) {
    return '$reason. BitDrop plays FLAC, ALAC, WAV, AIFF, MP3 and AAC.';
  }

  @override
  String missingExplain(String title) {
    return '\"$title\" was removed from Google Drive.';
  }

  @override
  String get removedFromDrive => 'Removed from Google Drive';

  @override
  String get formatNotSupported => 'Format not supported';

  @override
  String get nowPlayingLabel => 'Now playing';

  @override
  String artworkFor(String title) {
    return 'Artwork for $title';
  }

  @override
  String get albumArtwork => 'Album artwork';

  @override
  String outputIs(String tier) {
    return 'Output: $tier';
  }

  @override
  String get preamp => 'Preamp';

  @override
  String preampAuto(String db) {
    return 'Auto $db';
  }

  @override
  String clippingSamples(String count) {
    return 'Clipping · $count samples';
  }

  @override
  String clippingRisk(String db) {
    return 'Peak $db · clipping risk';
  }

  @override
  String get noClipping => 'No clipping';

  @override
  String get eqBypassed => 'BYPASSED';

  @override
  String eqGraphHint(int count) {
    return 'Equaliser response graph. $count bands. Use the band list below to edit values precisely.';
  }

  @override
  String eqBandEnabled(int id) {
    return 'Band $id enabled';
  }

  @override
  String eqRemoveBand(int id) {
    return 'Remove band $id';
  }

  @override
  String filterTypeIs(String filter) {
    return 'Filter type: $filter';
  }

  @override
  String peakMeters(String left, String right) {
    return 'Peak meters. Left $left, right $right';
  }

  @override
  String get spectrumLabel => 'Spectrum analyser';

  @override
  String get advanced => 'Advanced';

  @override
  String get less => 'Less';

  @override
  String get storageLabel => 'Storage';

  @override
  String storageFree(String size) {
    return 'Free $size';
  }

  @override
  String get scenarioSwitcher => 'Scenarios';

  @override
  String get componentGallery => 'Component gallery';

  @override
  String get themeSystem => 'System';

  @override
  String get themeLight => 'Light';

  @override
  String get themeDark => 'Dark';

  @override
  String get textScale => 'Text size';

  @override
  String get devTools => 'Developer';

  @override
  String get sourceUpToDate => 'Up to date';

  @override
  String get sourceSyncing => 'Syncing';

  @override
  String get sourceNeedsReconnect => 'Needs reconnection';

  @override
  String get sourceRateLimited => 'Paused · Drive is limiting requests';

  @override
  String get sourceOffline => 'Offline';

  @override
  String get sourceError => 'Error';

  @override
  String syncedSummary(String when, String tracks, int folders) {
    return 'Synced $when · $tracks tracks · $folders folders';
  }

  @override
  String retryingIn(String activity, int seconds) {
    return '$activity · retrying in ${seconds}s';
  }

  @override
  String changesSinceSync(String changes) {
    return 'Changes since last sync: $changes';
  }

  @override
  String get editFolders => 'Edit folders';

  @override
  String get playFolder => 'Play folder';

  @override
  String get pinFolder => 'Pin folder for offline';

  @override
  String folderSummary(int count, String size) {
    return '$count items · $size';
  }

  @override
  String get noOutputDevice => 'No output device';
}
