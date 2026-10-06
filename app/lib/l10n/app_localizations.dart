import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale) : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate = _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates = <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en')
  ];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'BitDrop'**
  String get appTitle;

  /// No description provided for @tagline.
  ///
  /// In en, this message translates to:
  /// **'Your lossless library. Your cloud. No compromises.'**
  String get tagline;

  /// No description provided for @tierBitPerfect.
  ///
  /// In en, this message translates to:
  /// **'Bit-perfect'**
  String get tierBitPerfect;

  /// No description provided for @tierNativeRate.
  ///
  /// In en, this message translates to:
  /// **'Native rate'**
  String get tierNativeRate;

  /// No description provided for @tierResampled.
  ///
  /// In en, this message translates to:
  /// **'Resampled'**
  String get tierResampled;

  /// No description provided for @tierUnknown.
  ///
  /// In en, this message translates to:
  /// **'Unknown'**
  String get tierUnknown;

  /// No description provided for @dspShort.
  ///
  /// In en, this message translates to:
  /// **'DSP'**
  String get dspShort;

  /// Shown wherever processing alters the samples.
  ///
  /// In en, this message translates to:
  /// **'DSP active'**
  String get dspActive;

  /// No description provided for @availCloudOnly.
  ///
  /// In en, this message translates to:
  /// **'Streams from cloud'**
  String get availCloudOnly;

  /// No description provided for @availPartial.
  ///
  /// In en, this message translates to:
  /// **'{percent}% cached'**
  String availPartial(int percent);

  /// No description provided for @availCached.
  ///
  /// In en, this message translates to:
  /// **'Cached on device'**
  String get availCached;

  /// No description provided for @availPinned.
  ///
  /// In en, this message translates to:
  /// **'Pinned for offline'**
  String get availPinned;

  /// No description provided for @availDownloading.
  ///
  /// In en, this message translates to:
  /// **'Downloading'**
  String get availDownloading;

  /// No description provided for @availUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Not available offline'**
  String get availUnavailable;

  /// No description provided for @availUnsupported.
  ///
  /// In en, this message translates to:
  /// **'Format not supported'**
  String get availUnsupported;

  /// No description provided for @availMissing.
  ///
  /// In en, this message translates to:
  /// **'Removed from cloud'**
  String get availMissing;

  /// No description provided for @actionPlay.
  ///
  /// In en, this message translates to:
  /// **'Play'**
  String get actionPlay;

  /// No description provided for @actionPause.
  ///
  /// In en, this message translates to:
  /// **'Pause'**
  String get actionPause;

  /// No description provided for @actionShuffle.
  ///
  /// In en, this message translates to:
  /// **'Shuffle'**
  String get actionShuffle;

  /// No description provided for @actionNext.
  ///
  /// In en, this message translates to:
  /// **'Next track'**
  String get actionNext;

  /// No description provided for @actionPrevious.
  ///
  /// In en, this message translates to:
  /// **'Previous track'**
  String get actionPrevious;

  /// No description provided for @actionPlayNext.
  ///
  /// In en, this message translates to:
  /// **'Play next'**
  String get actionPlayNext;

  /// No description provided for @actionAddToQueue.
  ///
  /// In en, this message translates to:
  /// **'Add to queue'**
  String get actionAddToQueue;

  /// No description provided for @actionAddToPlaylist.
  ///
  /// In en, this message translates to:
  /// **'Add to playlist'**
  String get actionAddToPlaylist;

  /// No description provided for @actionPinOffline.
  ///
  /// In en, this message translates to:
  /// **'Pin offline'**
  String get actionPinOffline;

  /// No description provided for @actionUnpin.
  ///
  /// In en, this message translates to:
  /// **'Unpin'**
  String get actionUnpin;

  /// No description provided for @actionClose.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get actionClose;

  /// No description provided for @actionDismiss.
  ///
  /// In en, this message translates to:
  /// **'Dismiss'**
  String get actionDismiss;

  /// No description provided for @actionCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get actionCancel;

  /// No description provided for @actionDone.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get actionDone;

  /// No description provided for @actionBack.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get actionBack;

  /// No description provided for @actionRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get actionRetry;

  /// No description provided for @actionReconnect.
  ///
  /// In en, this message translates to:
  /// **'Reconnect'**
  String get actionReconnect;

  /// No description provided for @actionRescan.
  ///
  /// In en, this message translates to:
  /// **'Rescan'**
  String get actionRescan;

  /// No description provided for @actionRemove.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get actionRemove;

  /// No description provided for @actionSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get actionSave;

  /// No description provided for @actionApply.
  ///
  /// In en, this message translates to:
  /// **'Apply'**
  String get actionApply;

  /// No description provided for @actionImport.
  ///
  /// In en, this message translates to:
  /// **'Import'**
  String get actionImport;

  /// No description provided for @actionSkip.
  ///
  /// In en, this message translates to:
  /// **'Skip'**
  String get actionSkip;

  /// No description provided for @actionContinue.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get actionContinue;

  /// No description provided for @actionGetStarted.
  ///
  /// In en, this message translates to:
  /// **'Get started'**
  String get actionGetStarted;

  /// No description provided for @actionGoToAlbum.
  ///
  /// In en, this message translates to:
  /// **'Go to album'**
  String get actionGoToAlbum;

  /// No description provided for @actionGoToArtist.
  ///
  /// In en, this message translates to:
  /// **'Go to artist'**
  String get actionGoToArtist;

  /// No description provided for @actionOpenFolder.
  ///
  /// In en, this message translates to:
  /// **'Open folder'**
  String get actionOpenFolder;

  /// No description provided for @actionMore.
  ///
  /// In en, this message translates to:
  /// **'More'**
  String get actionMore;

  /// No description provided for @actionMoreFor.
  ///
  /// In en, this message translates to:
  /// **'More options for {title}'**
  String actionMoreFor(String title);

  /// No description provided for @actionShuffleRemaining.
  ///
  /// In en, this message translates to:
  /// **'Shuffle remaining'**
  String get actionShuffleRemaining;

  /// No description provided for @actionSaveAsPlaylist.
  ///
  /// In en, this message translates to:
  /// **'Save as playlist'**
  String get actionSaveAsPlaylist;

  /// No description provided for @actionClear.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get actionClear;

  /// No description provided for @actionUndo.
  ///
  /// In en, this message translates to:
  /// **'Undo'**
  String get actionUndo;

  /// No description provided for @actionSelectAll.
  ///
  /// In en, this message translates to:
  /// **'Select all'**
  String get actionSelectAll;

  /// No description provided for @repeatOff.
  ///
  /// In en, this message translates to:
  /// **'Repeat off'**
  String get repeatOff;

  /// No description provided for @repeatAll.
  ///
  /// In en, this message translates to:
  /// **'Repeat all'**
  String get repeatAll;

  /// No description provided for @repeatOne.
  ///
  /// In en, this message translates to:
  /// **'Repeat one'**
  String get repeatOne;

  /// No description provided for @shuffleOn.
  ///
  /// In en, this message translates to:
  /// **'Shuffle on'**
  String get shuffleOn;

  /// No description provided for @shuffleOff.
  ///
  /// In en, this message translates to:
  /// **'Shuffle off'**
  String get shuffleOff;

  /// No description provided for @seekPosition.
  ///
  /// In en, this message translates to:
  /// **'Playback position'**
  String get seekPosition;

  /// No description provided for @seekCached.
  ///
  /// In en, this message translates to:
  /// **'Cached'**
  String get seekCached;

  /// No description provided for @seekWillStream.
  ///
  /// In en, this message translates to:
  /// **'Will stream'**
  String get seekWillStream;

  /// No description provided for @seekRemainingHint.
  ///
  /// In en, this message translates to:
  /// **'Remaining time. Tap for total duration.'**
  String get seekRemainingHint;

  /// No description provided for @seekTotalHint.
  ///
  /// In en, this message translates to:
  /// **'Total duration. Tap for remaining time.'**
  String get seekTotalHint;

  /// No description provided for @bufferingLabel.
  ///
  /// In en, this message translates to:
  /// **'Buffering'**
  String get bufferingLabel;

  /// No description provided for @bufferingSlow.
  ///
  /// In en, this message translates to:
  /// **'Slow connection — building a bigger buffer'**
  String get bufferingSlow;

  /// No description provided for @bufferingDetail.
  ///
  /// In en, this message translates to:
  /// **'Buffering · {buffered} s of {target} s'**
  String bufferingDetail(String buffered, String target);

  /// No description provided for @bufferAhead.
  ///
  /// In en, this message translates to:
  /// **'Buffer {seconds} s'**
  String bufferAhead(String seconds);

  /// No description provided for @navHome.
  ///
  /// In en, this message translates to:
  /// **'Home'**
  String get navHome;

  /// No description provided for @navLibrary.
  ///
  /// In en, this message translates to:
  /// **'Library'**
  String get navLibrary;

  /// No description provided for @navSearch.
  ///
  /// In en, this message translates to:
  /// **'Search'**
  String get navSearch;

  /// No description provided for @navSources.
  ///
  /// In en, this message translates to:
  /// **'Sources'**
  String get navSources;

  /// No description provided for @navSettings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get navSettings;

  /// No description provided for @navQueue.
  ///
  /// In en, this message translates to:
  /// **'Queue'**
  String get navQueue;

  /// No description provided for @navEq.
  ///
  /// In en, this message translates to:
  /// **'EQ'**
  String get navEq;

  /// No description provided for @navOutput.
  ///
  /// In en, this message translates to:
  /// **'Output'**
  String get navOutput;

  /// No description provided for @navLyrics.
  ///
  /// In en, this message translates to:
  /// **'Lyrics'**
  String get navLyrics;

  /// No description provided for @signalPathTitle.
  ///
  /// In en, this message translates to:
  /// **'Signal path'**
  String get signalPathTitle;

  /// No description provided for @signalSource.
  ///
  /// In en, this message translates to:
  /// **'Source'**
  String get signalSource;

  /// No description provided for @signalDecoder.
  ///
  /// In en, this message translates to:
  /// **'Decoder'**
  String get signalDecoder;

  /// No description provided for @signalDsp.
  ///
  /// In en, this message translates to:
  /// **'DSP'**
  String get signalDsp;

  /// No description provided for @signalVolume.
  ///
  /// In en, this message translates to:
  /// **'Volume'**
  String get signalVolume;

  /// No description provided for @signalOutput.
  ///
  /// In en, this message translates to:
  /// **'Output'**
  String get signalOutput;

  /// No description provided for @signalDevice.
  ///
  /// In en, this message translates to:
  /// **'Device'**
  String get signalDevice;

  /// No description provided for @signalDspOff.
  ///
  /// In en, this message translates to:
  /// **'Off — bypassed'**
  String get signalDspOff;

  /// No description provided for @signalDspOffDetail.
  ///
  /// In en, this message translates to:
  /// **'True bypass: samples pass through untouched.'**
  String get signalDspOffDetail;

  /// No description provided for @signalDspOnDetail.
  ///
  /// In en, this message translates to:
  /// **'Processing changes the samples, so bit-perfect is not possible while this is on.'**
  String get signalDspOnDetail;

  /// No description provided for @signalVolumeDac.
  ///
  /// In en, this message translates to:
  /// **'DAC hardware'**
  String get signalVolumeDac;

  /// No description provided for @signalVolumeSoftware.
  ///
  /// In en, this message translates to:
  /// **'Software, 24-bit dithered'**
  String get signalVolumeSoftware;

  /// No description provided for @signalVolumeSystem.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get signalVolumeSystem;

  /// No description provided for @signalVolumeDacDetail.
  ///
  /// In en, this message translates to:
  /// **'BitDrop applies no digital gain. Use the volume keys.'**
  String get signalVolumeDacDetail;

  /// No description provided for @signalVolumeSoftwareDetail.
  ///
  /// In en, this message translates to:
  /// **'Digital gain is applied before output.'**
  String get signalVolumeSoftwareDetail;

  /// No description provided for @signalVolumeSystemDetail.
  ///
  /// In en, this message translates to:
  /// **'Android controls the level.'**
  String get signalVolumeSystemDetail;

  /// No description provided for @signalOutputBitPerfect.
  ///
  /// In en, this message translates to:
  /// **'Bit-perfect USB'**
  String get signalOutputBitPerfect;

  /// No description provided for @signalOutputNative.
  ///
  /// In en, this message translates to:
  /// **'Native rate'**
  String get signalOutputNative;

  /// No description provided for @signalOutputResampled.
  ///
  /// In en, this message translates to:
  /// **'Android mixer → {rate}'**
  String signalOutputResampled(String rate);

  /// No description provided for @signalFormatsMatch.
  ///
  /// In en, this message translates to:
  /// **'Requested format matched exactly.'**
  String get signalFormatsMatch;

  /// No description provided for @signalFormatsDiffer.
  ///
  /// In en, this message translates to:
  /// **'Requested {requested}, got {actual}.'**
  String signalFormatsDiffer(String requested, String actual);

  /// No description provided for @signalNoDevice.
  ///
  /// In en, this message translates to:
  /// **'No device'**
  String get signalNoDevice;

  /// No description provided for @signalCachedStreaming.
  ///
  /// In en, this message translates to:
  /// **'{percent}% cached · streaming {rate}'**
  String signalCachedStreaming(int percent, String rate);

  /// No description provided for @signalCachedOffline.
  ///
  /// In en, this message translates to:
  /// **'{percent}% cached · offline'**
  String signalCachedOffline(int percent);

  /// No description provided for @signalSourceBitrate.
  ///
  /// In en, this message translates to:
  /// **'{rate} source bitrate'**
  String signalSourceBitrate(String rate);

  /// No description provided for @signalDeviceCaps.
  ///
  /// In en, this message translates to:
  /// **'Supports {rates} kHz · {depths}-bit · Hardware volume: {volume}'**
  String signalDeviceCaps(String rates, String depths, String volume);

  /// No description provided for @requestedVsActual.
  ///
  /// In en, this message translates to:
  /// **'Requested vs. actual'**
  String get requestedVsActual;

  /// No description provided for @colRequested.
  ///
  /// In en, this message translates to:
  /// **'Requested'**
  String get colRequested;

  /// No description provided for @colActual.
  ///
  /// In en, this message translates to:
  /// **'Actual'**
  String get colActual;

  /// No description provided for @rowCodec.
  ///
  /// In en, this message translates to:
  /// **'Codec'**
  String get rowCodec;

  /// No description provided for @rowBitDepth.
  ///
  /// In en, this message translates to:
  /// **'Bit depth'**
  String get rowBitDepth;

  /// No description provided for @rowSampleRate.
  ///
  /// In en, this message translates to:
  /// **'Sample rate'**
  String get rowSampleRate;

  /// No description provided for @rowChannels.
  ///
  /// In en, this message translates to:
  /// **'Channels'**
  String get rowChannels;

  /// No description provided for @rowVolume.
  ///
  /// In en, this message translates to:
  /// **'Volume'**
  String get rowVolume;

  /// No description provided for @turnOffEqForBitPerfect.
  ///
  /// In en, this message translates to:
  /// **'Turn off EQ for bit-perfect'**
  String get turnOffEqForBitPerfect;

  /// No description provided for @runSafetyCheck.
  ///
  /// In en, this message translates to:
  /// **'Run safety check'**
  String get runSafetyCheck;

  /// No description provided for @openDiagnostics.
  ///
  /// In en, this message translates to:
  /// **'Open diagnostics'**
  String get openDiagnostics;

  /// No description provided for @hwVolumeYes.
  ///
  /// In en, this message translates to:
  /// **'Yes'**
  String get hwVolumeYes;

  /// No description provided for @hwVolumeNo.
  ///
  /// In en, this message translates to:
  /// **'No'**
  String get hwVolumeNo;

  /// No description provided for @hwVolumeUnknown.
  ///
  /// In en, this message translates to:
  /// **'Unknown'**
  String get hwVolumeUnknown;

  /// No description provided for @hardwareVolume.
  ///
  /// In en, this message translates to:
  /// **'Hardware volume'**
  String get hardwareVolume;

  /// No description provided for @sampleRatesUnit.
  ///
  /// In en, this message translates to:
  /// **'Sample rates (kHz)'**
  String get sampleRatesUnit;

  /// No description provided for @bitDepthsUnit.
  ///
  /// In en, this message translates to:
  /// **'Bit depths (bit)'**
  String get bitDepthsUnit;

  /// No description provided for @savedProfile.
  ///
  /// In en, this message translates to:
  /// **'Saved profile'**
  String get savedProfile;

  /// No description provided for @unsupportedExplain.
  ///
  /// In en, this message translates to:
  /// **'{reason}. BitDrop plays FLAC, ALAC, WAV, AIFF, MP3 and AAC.'**
  String unsupportedExplain(String reason);

  /// No description provided for @missingExplain.
  ///
  /// In en, this message translates to:
  /// **'\"{title}\" was removed from Google Drive.'**
  String missingExplain(String title);

  /// No description provided for @removedFromDrive.
  ///
  /// In en, this message translates to:
  /// **'Removed from Google Drive'**
  String get removedFromDrive;

  /// No description provided for @formatNotSupported.
  ///
  /// In en, this message translates to:
  /// **'Format not supported'**
  String get formatNotSupported;

  /// No description provided for @nowPlayingLabel.
  ///
  /// In en, this message translates to:
  /// **'Now playing'**
  String get nowPlayingLabel;

  /// No description provided for @artworkFor.
  ///
  /// In en, this message translates to:
  /// **'Artwork for {title}'**
  String artworkFor(String title);

  /// No description provided for @albumArtwork.
  ///
  /// In en, this message translates to:
  /// **'Album artwork'**
  String get albumArtwork;

  /// No description provided for @outputIs.
  ///
  /// In en, this message translates to:
  /// **'Output: {tier}'**
  String outputIs(String tier);

  /// No description provided for @preamp.
  ///
  /// In en, this message translates to:
  /// **'Preamp'**
  String get preamp;

  /// No description provided for @preampAuto.
  ///
  /// In en, this message translates to:
  /// **'Auto {db}'**
  String preampAuto(String db);

  /// No description provided for @clippingSamples.
  ///
  /// In en, this message translates to:
  /// **'Clipping · {count} samples'**
  String clippingSamples(String count);

  /// No description provided for @clippingRisk.
  ///
  /// In en, this message translates to:
  /// **'Peak {db} · clipping risk'**
  String clippingRisk(String db);

  /// No description provided for @noClipping.
  ///
  /// In en, this message translates to:
  /// **'No clipping'**
  String get noClipping;

  /// No description provided for @eqBypassed.
  ///
  /// In en, this message translates to:
  /// **'BYPASSED'**
  String get eqBypassed;

  /// No description provided for @eqGraphHint.
  ///
  /// In en, this message translates to:
  /// **'Equaliser response graph. {count} bands. Use the band list below to edit values precisely.'**
  String eqGraphHint(int count);

  /// No description provided for @eqBandEnabled.
  ///
  /// In en, this message translates to:
  /// **'Band {id} enabled'**
  String eqBandEnabled(int id);

  /// No description provided for @eqRemoveBand.
  ///
  /// In en, this message translates to:
  /// **'Remove band {id}'**
  String eqRemoveBand(int id);

  /// No description provided for @filterTypeIs.
  ///
  /// In en, this message translates to:
  /// **'Filter type: {filter}'**
  String filterTypeIs(String filter);

  /// No description provided for @peakMeters.
  ///
  /// In en, this message translates to:
  /// **'Peak meters. Left {left}, right {right}'**
  String peakMeters(String left, String right);

  /// No description provided for @spectrumLabel.
  ///
  /// In en, this message translates to:
  /// **'Spectrum analyser'**
  String get spectrumLabel;

  /// No description provided for @advanced.
  ///
  /// In en, this message translates to:
  /// **'Advanced'**
  String get advanced;

  /// No description provided for @less.
  ///
  /// In en, this message translates to:
  /// **'Less'**
  String get less;

  /// No description provided for @storageLabel.
  ///
  /// In en, this message translates to:
  /// **'Storage'**
  String get storageLabel;

  /// No description provided for @storageFree.
  ///
  /// In en, this message translates to:
  /// **'Free {size}'**
  String storageFree(String size);

  /// No description provided for @scenarioSwitcher.
  ///
  /// In en, this message translates to:
  /// **'Scenarios'**
  String get scenarioSwitcher;

  /// No description provided for @componentGallery.
  ///
  /// In en, this message translates to:
  /// **'Component gallery'**
  String get componentGallery;

  /// No description provided for @themeSystem.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get themeSystem;

  /// No description provided for @themeLight.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get themeLight;

  /// No description provided for @themeDark.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get themeDark;

  /// No description provided for @textScale.
  ///
  /// In en, this message translates to:
  /// **'Text size'**
  String get textScale;

  /// No description provided for @devTools.
  ///
  /// In en, this message translates to:
  /// **'Developer'**
  String get devTools;

  /// No description provided for @sourceUpToDate.
  ///
  /// In en, this message translates to:
  /// **'Up to date'**
  String get sourceUpToDate;

  /// No description provided for @sourceSyncing.
  ///
  /// In en, this message translates to:
  /// **'Syncing'**
  String get sourceSyncing;

  /// No description provided for @sourceNeedsReconnect.
  ///
  /// In en, this message translates to:
  /// **'Needs reconnection'**
  String get sourceNeedsReconnect;

  /// No description provided for @sourceRateLimited.
  ///
  /// In en, this message translates to:
  /// **'Paused · Drive is limiting requests'**
  String get sourceRateLimited;

  /// No description provided for @sourceOffline.
  ///
  /// In en, this message translates to:
  /// **'Offline'**
  String get sourceOffline;

  /// No description provided for @sourceError.
  ///
  /// In en, this message translates to:
  /// **'Error'**
  String get sourceError;

  /// No description provided for @syncedSummary.
  ///
  /// In en, this message translates to:
  /// **'Synced {when} · {tracks} tracks · {folders} folders'**
  String syncedSummary(String when, String tracks, int folders);

  /// No description provided for @retryingIn.
  ///
  /// In en, this message translates to:
  /// **'{activity} · retrying in {seconds}s'**
  String retryingIn(String activity, int seconds);

  /// No description provided for @changesSinceSync.
  ///
  /// In en, this message translates to:
  /// **'Changes since last sync: {changes}'**
  String changesSinceSync(String changes);

  /// No description provided for @editFolders.
  ///
  /// In en, this message translates to:
  /// **'Edit folders'**
  String get editFolders;

  /// No description provided for @playFolder.
  ///
  /// In en, this message translates to:
  /// **'Play folder'**
  String get playFolder;

  /// No description provided for @pinFolder.
  ///
  /// In en, this message translates to:
  /// **'Pin folder for offline'**
  String get pinFolder;

  /// No description provided for @folderSummary.
  ///
  /// In en, this message translates to:
  /// **'{count} items · {size}'**
  String folderSummary(int count, String size);

  /// No description provided for @noOutputDevice.
  ///
  /// In en, this message translates to:
  /// **'No output device'**
  String get noOutputDevice;
}

class _AppLocalizationsDelegate extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) => <String>['en'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {


  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en': return AppLocalizationsEn();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.'
  );
}
