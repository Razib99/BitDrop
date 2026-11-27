import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:rxdart/rxdart.dart';

import '../core_api/enums.dart';
import '../core_api/models.dart';
import '../core_live/cloud_library.dart';
import '../core_live/output_device.dart';
import '../src/rust/api/audio_engine.dart' as rust;
import 'bitdrop_settings_repository.dart';

/// Coordinates hardware output device probing, routing lifecycle changes
/// (earphone disconnect, noisy audio, interruptions), UAC2 direct USB mode,
/// and BitDrop Signal Path resolution.
class BitDropOutputCoordinator {
  final OutputDeviceProbe _outputProbe;
  final _signalPath = BehaviorSubject<SignalPath>.seeded(_unknownPath);

  StreamSubscription<OutputDevice?>? _outputProbeSub;
  (String deviceId, int sampleRate, int bitDepth, bool bitPerfect)?
      _lastMixerConfigKey;
  (String deviceId, int sampleRate, int bitDepth, bool bitPerfect)?
      _inFlightMixerKey;
  (String deviceId, int sampleRate, int bitDepth, bool bitPerfect)?
      _lastFailedMixerKey;
  (String deviceId, int sampleRate, int bitDepth)? _lastRejectedBitPerfectKey;
  Future<void> _mixerUpdateChain = Future<void>.value();

  VoidCallback? onEarphoneDisconnected;
  VoidCallback? onBecomingNoisy;
  VoidCallback? onInterruptionBegan;
  ValueChanged<bool>? onInterruptionEnded;
  VoidCallback? onDirectUsbAutoAttachNeeded;
  ValueChanged<UsbAudioDevice>? onUsbPermissionNeeded;
  VoidCallback? onUsbPermissionResolved;

  Track? Function()? currentTrackProvider;
  CloudLibrary? Function()? cloudProvider;
  bool Function()? isDirectUsbDriverEnabled;
  bool Function()? isPreferBitPerfectEnabled;
  double Function()? softwareVolumeDbProvider;
  bool Function()? isSafetyAttenuationEnabled;
  EqState? Function()? eqStateProvider;
  rust.EngineOutputState Function()? engineOutputStateProvider;

  static const _unknownPath = SignalPath(
    tier: OutputTier.unknown,
    source: AudioFormat(codec: Codec.flac, bitDepth: 0, sampleRate: 0),
    requested: AudioFormat(codec: Codec.flac, bitDepth: 0, sampleRate: 0),
    actual: AudioFormat(codec: Codec.flac, bitDepth: 0, sampleRate: 0),
    dspActive: false,
    volume: VolumeMode.system,
    explanation: 'Nothing is playing yet, so there is no output path to report.',
  );

  BitDropOutputCoordinator({
    OutputDeviceProbe? outputProbe,
    this.onEarphoneDisconnected,
    this.onBecomingNoisy,
    this.onInterruptionBegan,
    this.onInterruptionEnded,
    this.onDirectUsbAutoAttachNeeded,
    this.onUsbPermissionNeeded,
    this.onUsbPermissionResolved,
    this.currentTrackProvider,
    this.cloudProvider,
    this.isDirectUsbDriverEnabled,
    this.isPreferBitPerfectEnabled,
    this.softwareVolumeDbProvider,
    this.isSafetyAttenuationEnabled,
    this.eqStateProvider,
    this.engineOutputStateProvider,
  }) : _outputProbe = outputProbe ?? OutputDeviceProbe();

  Stream<OutputDevice?> get outputDevice => _outputProbe.stream;
  OutputDevice? get currentDevice => _outputProbe.current;

  Stream<SignalPath> get signalPath => _signalPath.stream;
  SignalPath get currentSignalPath => _signalPath.value;

  OutputDeviceProbe get probe => _outputProbe;

  static bool isEarphone(DeviceType? type) =>
      type == DeviceType.usb ||
      type == DeviceType.wiredAnalog ||
      type == DeviceType.bluetooth;

  void start() {
    _outputProbe.start();
    DeviceType? previousType = _outputProbe.current?.type;

    _outputProbeSub = _outputProbe.stream.listen((device) {
      if (device?.systemSampleRate != null && device!.systemSampleRate! > 0) {
        try {
          rust.engineSetHardwareSampleRate(rate: device.systemSampleRate!);
        } catch (_) {}
      }
      final newType = device?.type;
      final wasEarphone = isEarphone(previousType);
      final isNowEarphone = isEarphone(newType);

      if (wasEarphone && !isNowEarphone) {
        onEarphoneDisconnected?.call();
      }

      if (newType == DeviceType.usb) {
        if (isDirectUsbDriverEnabled?.call() == true &&
            onDirectUsbAutoAttachNeeded != null) {
          onDirectUsbAutoAttachNeeded!();
        } else {
          unawaited(evaluateUsbAutoAttach(device: device));
        }
      } else {
        onUsbPermissionResolved?.call();
      }
      previousType = newType;
      recomputeSignalPath();
    });

    if (_outputProbe.current?.type == DeviceType.usb) {
      unawaited(evaluateUsbAutoAttach(device: _outputProbe.current));
    }

    _outputProbe.onBecomingNoisy = () {
      onBecomingNoisy?.call();
    };

    _outputProbe.onInterruptionBegan = () {
      onInterruptionBegan?.call();
    };

    _outputProbe.onInterruptionEnded = (shouldResume) {
      onInterruptionEnded?.call(shouldResume);
    };

    _outputProbe.onUsbDeviceDetached = (devId) {
      onBecomingNoisy?.call();
      onUsbPermissionResolved?.call();
      recomputeSignalPath();
    };
  }

  static bool supportsOsBitPerfectForRate(OutputDevice device, int? sampleRate) {
    if (!device.supportsBitPerfect) return false;
    if (sampleRate == null || sampleRate <= 0) return true;
    return device.bitPerfectRates.isEmpty ||
        device.bitPerfectRates.contains(sampleRate);
  }

  bool shouldAutoEngageDirectUsb(OutputDevice? device, {int? trackSampleRate}) {
    if (device == null || device.type != DeviceType.usb) return false;
    if (isDirectUsbDriverEnabled?.call() == true) return true;
    if (isPreferBitPerfectEnabled?.call() == true) {
      if (_lastRejectedBitPerfectKey != null &&
          _lastRejectedBitPerfectKey!.$1 == device.id &&
          (trackSampleRate == null ||
              trackSampleRate <= 0 ||
              _lastRejectedBitPerfectKey!.$2 == trackSampleRate)) {
        return true;
      }
      return !supportsOsBitPerfectForRate(device, trackSampleRate);
    }
    return false;
  }

  /// Checks whether Direct USB should engage for the active USB device and
  /// attaches immediately if permission is already granted, or notifies UI
  /// via [onUsbPermissionNeeded] so the user can authorize in one tap.
  Future<bool> evaluateUsbAutoAttach({
    OutputDevice? device,
    int? trackSampleRate,
  }) async {
    final target = device ?? _outputProbe.current;
    final sr = trackSampleRate ?? currentTrackProvider?.call()?.format.sampleRate;
    if (!shouldAutoEngageDirectUsb(target, trackSampleRate: sr)) {
      if (target?.type != DeviceType.usb) {
        onUsbPermissionResolved?.call();
      }
      return false;
    }
    return engageDirectUsb(
      requestPermission: false,
      sampleRate: sr ?? 0,
      bitDepth: currentTrackProvider?.call()?.format.bitDepth ?? 0,
    );
  }

  UsbAudioDevice? _selectUsbDevice(
    List<UsbAudioDevice> devices, {
    int? deviceId,
    String? preferredName,
  }) {
    if (devices.isEmpty) return null;
    if (deviceId != null) {
      for (final d in devices) {
        if (d.deviceId == deviceId) return d;
      }
    }
    final wanted = preferredName?.trim().toLowerCase() ?? '';
    if (wanted.isNotEmpty) {
      for (final d in devices) {
        final p = d.productName.trim().toLowerCase();
        if (p.isNotEmpty && (wanted.contains(p) || p.contains(wanted))) {
          return d;
        }
      }
    }
    return devices.first;
  }

  Future<bool> engageDirectUsb({
    bool requestPermission = true,
    int? deviceId,
    int sampleRate = 0,
    int bitDepth = 0,
  }) async {
    try {
      final backend = _outputProbe.getStreamBackend();
      if (backend == 'DirectUsb') {
        onUsbPermissionResolved?.call();
        return true;
      }
      final usbDevices = await _outputProbe.listUsbAudioDevices();
      final targetDev = _selectUsbDevice(
        usbDevices,
        deviceId: deviceId,
        preferredName: _outputProbe.current?.name,
      );
      if (targetDev == null) return false;

      if (!targetDev.hasPermission) {
        if (!requestPermission) {
          onUsbPermissionNeeded?.call(targetDev);
          return false;
        }
        final granted =
            await _outputProbe.requestUsbPermission(targetDev.deviceId);
        if (!granted) {
          debugPrint(
            '[usb] Permission denied for direct USB device ${targetDev.deviceId}',
          );
          return false;
        }
      }

      final trackFormat = currentTrackProvider?.call()?.format;
      final sr = sampleRate > 0 ? sampleRate : (trackFormat?.sampleRate ?? 0);
      final bits = bitDepth > 0 ? bitDepth : (trackFormat?.bitDepth ?? 0);
      final diag = await _outputProbe.attachDirectUsbDac(
        deviceId: targetDev.deviceId,
        sampleRate: sr,
        bitDepth: bits,
      );
      if (diag == null) return false;
      onUsbPermissionResolved?.call();
      recomputeSignalPath();
      return true;
    } catch (e) {
      debugPrint('[usb] Failed to engage direct USB DAC: $e');
      return false;
    }
  }

  Future<void> autoAttachDirectUsbIfPossible() =>
      engageDirectUsb(requestPermission: false);

  Future<void> handleDirectUsbDriverSetting(bool enabled) async {
    if (!enabled) {
      await _outputProbe.detachDirectUsbDac();
      onUsbPermissionResolved?.call();
      recomputeSignalPath();
      return;
    }
    await engageDirectUsb(requestPermission: true);
  }

  void recomputeSignalPath() {
    if (_signalPath.isClosed) return;
    final rust.EngineOutputState out;
    try {
      out = (engineOutputStateProvider ?? rust.engineOutputState)();
    } catch (_) {
      if (!_signalPath.isClosed) _signalPath.add(_unknownPath);
      return;
    }
    if (!out.hasTrack || out.sourceSampleRate == 0) {
      if (!_signalPath.isClosed) _signalPath.add(_unknownPath);
      return;
    }

    final device = _outputProbe.current;
    final codec = _codecFromName(out.sourceCodec);

    final track = currentTrackProvider?.call();
    final sourceBitDepth = out.sourceBits == 0 ? 16 : out.sourceBits;
    final sourceChannels = out.sourceChannels == 0 ? 2 : out.sourceChannels;

    final source = AudioFormat(
      codec: codec,
      bitDepth: sourceBitDepth,
      sampleRate: out.sourceSampleRate,
      bitrateKbps: track?.format.bitrateKbps,
      channels: sourceChannels,
    );

    String streamBackend = 'Standard';
    try {
      streamBackend = rust.engineGetStreamBackend();
    } catch (_) {}
    final isDirectUsb = streamBackend == 'DirectUsb';

    final swVolDb = softwareVolumeDbProvider?.call() ?? 0.0;
    final swAttenuating = swVolDb < -0.01;
    final dsp = out.dspActive || swAttenuating;
    final effectiveStreamRate = source.codec == Codec.dsf && !isDirectUsb
        ? 176400
        : source.sampleRate;
    final effectiveBitDepth = source.bitDepth > 0 ? source.bitDepth : 16;
    if (isDirectUsb ||
        device == null ||
        (_lastRejectedBitPerfectKey != null &&
            _lastRejectedBitPerfectKey!.$1 != device.id)) {
      _lastRejectedBitPerfectKey = null;
      _lastFailedMixerKey = null;
    }
    final bitPerfectRejected = _lastRejectedBitPerfectKey ==
        (device?.id, effectiveStreamRate, effectiveBitDepth);
    final supportsSourceRateBitPerfect = device != null &&
        device.supportsBitPerfect &&
        !bitPerfectRejected &&
        (device.bitPerfectRates.isEmpty ||
            device.bitPerfectRates.contains(effectiveStreamRate));
    final isExclusiveBitPerfect = isDirectUsb ||
        ((device?.type == DeviceType.usb && supportsSourceRateBitPerfect) &&
            !dsp);

    final hwRate = out.hardwareSampleRate != 0
        ? out.hardwareSampleRate
        : (device?.systemSampleRate ?? 0);

    final resampled = !isDirectUsb &&
        ((!isExclusiveBitPerfect &&
                hwRate != 0 &&
                hwRate != source.sampleRate) ||
            (out.outputSampleRate != 0 &&
                out.outputSampleRate != source.sampleRate));

    final actualSampleRate = isDirectUsb
        ? (out.hardwareSampleRate != 0
            ? out.hardwareSampleRate
            : source.sampleRate)
        : (resampled && hwRate != 0
            ? hwRate
            : (out.outputSampleRate == 0
                ? source.sampleRate
                : out.outputSampleRate));
    final actualBitDepth = isDirectUsb && out.hardwareFormat.isNotEmpty
        ? (out.hardwareFormat.contains('32')
            ? 32
            : (out.hardwareFormat.contains('24') ? 24 : 16))
        : sourceBitDepth;
    final actualBitrate =
        (actualBitDepth * actualSampleRate * sourceChannels) ~/ 1000;
    final actual = source.copyWith(
      bitDepth: actualBitDepth,
      sampleRate: actualSampleRate,
      bitrateKbps: actualBitrate,
    );

    final bool isRateShifted =
        !isDirectUsb && (actualSampleRate != source.sampleRate);

    final OutputTier tier;
    if (isDirectUsb) {
      tier = dsp ? OutputTier.nativeRate : OutputTier.bitPerfect;
    } else if (isRateShifted) {
      tier = OutputTier.resampled;
    } else if (isExclusiveBitPerfect) {
      tier = OutputTier.bitPerfect;
    } else {
      tier = OutputTier.nativeRate;
    }

    if (device?.type == DeviceType.usb && _supported && !isDirectUsb) {
      _syncUsbMixerAttributesAndReopenIfNeeded(
        device: device!,
        sampleRate: effectiveStreamRate,
        bitDepth: source.bitDepth,
        bitPerfect: !dsp && supportsSourceRateBitPerfect,
        currentOutputRate: out.outputSampleRate,
      );
    } else {
      _lastMixerConfigKey = null;
      _inFlightMixerKey = null;
      if (device?.type != DeviceType.usb || isDirectUsb) {
        _lastRejectedBitPerfectKey = null;
      }
    }

    final eqState = eqStateProvider?.call();
    final dspChain = <String>[
      if (eqState != null)
        ...BitDropSettingsRepository.describeDspChain(
          eqState,
          engineDspActive: out.dspActive && !swAttenuating,
        )
      else if (out.dspActive && !swAttenuating)
        'Equaliser',
      if (swAttenuating)
        isSafetyAttenuationEnabled?.call() == true
            ? 'Safety attenuation (${swVolDb.toStringAsFixed(1)} dB)'
            : 'Digital volume (${swVolDb.toStringAsFixed(1)} dB)',
    ];

    final cloud = cloudProvider?.call();
    final currentTrackId = track?.id ?? '';

    final bool engineSincResampled = !isDirectUsb &&
        source.codec != Codec.dsf &&
        out.outputSampleRate != 0 &&
        out.outputSampleRate != source.sampleRate &&
        actualSampleRate == out.outputSampleRate;

    _signalPath.add(SignalPath(
      tier: tier,
      source: source,
      requested: source,
      actual: actual,
      dspActive: dsp,
      dspChain: dspChain,
      volume: dsp ? VolumeMode.softwareDithered : VolumeMode.system,
      device: device,
      sourceLabel:
          cloud?.trackById(currentTrackId) != null ? 'Google Drive' : 'This device',
      decoderLabel: source.codec == Codec.dsf
          ? (isDirectUsb
              ? '${source.shortLabel} Bitstream -> DoP v1.1 Framing'
              : '${source.shortLabel} -> 176.4 kHz / 24-bit Polyphase FIR Decimation')
          : '${source.codec.label} -> '
              '${source.bitDepth}-bit integer PCM',
      explanation: _explain(
        tier,
        source,
        actual,
        dsp,
        device,
        isDirectUsb: isDirectUsb,
        engineSincResampled: engineSincResampled,
      ),
    ));
  }

  bool _isDspCurrentlyActive() {
    if ((softwareVolumeDbProvider?.call() ?? 0.0) < -0.01) {
      return true;
    }
    try {
      return rust.engineOutputState().dspActive;
    } catch (_) {
      final eq = eqStateProvider?.call();
      if (eq == null) return false;
      final eqBandsActive = !eq.bypass &&
          (eq.preampDb.abs() > 0.01 ||
              eq.bands.any((b) => b.enabled && b.gainDb.abs() > 0.01) ||
              eq.graphicGains.any((g) => g.abs() > 0.01));
      return eqBandsActive ||
          eq.replayGain != ReplayGainMode.off ||
          eq.crossfeed != CrossfeedPreset.off;
    }
  }

  /// Synchronizes Direct USB auto-attach and Android 14+ / iOS preferred mixer
  /// attributes BEFORE Rust opens a new track's output stream so bit-perfect
  /// engages on frame 0 without racing stream creation.
  Future<void> prepareForTrackFormat(int sampleRate, int bitDepth) {
    final op = _mixerUpdateChain.then((_) async {
      if (!_supported) return;
      final device = _outputProbe.current;
      if (device == null || device.type != DeviceType.usb) {
        _lastMixerConfigKey = null;
        _inFlightMixerKey = null;
        _lastFailedMixerKey = null;
        _lastRejectedBitPerfectKey = null;
        return;
      }

      String streamBackend = 'Standard';
      try {
        streamBackend = rust.engineGetStreamBackend();
      } catch (_) {}
      if (streamBackend == 'DirectUsb') {
        _lastFailedMixerKey = null;
        _lastRejectedBitPerfectKey = null;
        return;
      }

      final bits = bitDepth > 0 ? bitDepth : 16;
      final dsp = _isDspCurrentlyActive();
      final rejectedAlready = sampleRate > 0 &&
          _lastRejectedBitPerfectKey == (device.id, sampleRate, bits);
      final supportsRate = !rejectedAlready &&
          (sampleRate > 0
              ? supportsOsBitPerfectForRate(device, sampleRate)
              : device.supportsBitPerfect);

      // Await USB auto-attach inside the pre-open barrier so DirectUsb is
      // active before frame 0 opens (non-blocking if permission isn't granted).
      if ((!supportsRate || isDirectUsbDriverEnabled?.call() == true) &&
          (isPreferBitPerfectEnabled?.call() == true ||
              isDirectUsbDriverEnabled?.call() == true)) {
        await evaluateUsbAutoAttach(
          device: device,
          trackSampleRate: sampleRate > 0 ? sampleRate : null,
        );
        try {
          streamBackend = rust.engineGetStreamBackend();
        } catch (_) {}
        if (streamBackend == 'DirectUsb') {
          _lastFailedMixerKey = null;
          _lastRejectedBitPerfectKey = null;
          return;
        }
      }

      if (sampleRate <= 0) return;

      final bitPerfect = !dsp && supportsRate;
      final key = (device.id, sampleRate, bits, bitPerfect);
      if (key == _lastMixerConfigKey || key == _lastFailedMixerKey) return;

      _inFlightMixerKey = key;
      try {
        final ok = await _outputProbe.setPreferredMixerAttributes(
          sampleRate: sampleRate,
          bitDepth: bits,
          bitPerfect: bitPerfect,
        );
        if (ok) {
          _lastMixerConfigKey = key;
          _lastFailedMixerKey = null;
          _lastRejectedBitPerfectKey = null;
        } else {
          _lastMixerConfigKey = null;
          _lastFailedMixerKey = key;
          if (bitPerfect) {
            _lastRejectedBitPerfectKey = (device.id, sampleRate, bits);
            if (isPreferBitPerfectEnabled?.call() == true) {
              await evaluateUsbAutoAttach(
                device: device,
                trackSampleRate: sampleRate,
              );
            }
          }
        }
      } finally {
        if (_inFlightMixerKey == key) _inFlightMixerKey = null;
      }
    }).catchError((Object e) {
      debugPrint('[output] prepareForTrackFormat failed: $e');
    });
    _mixerUpdateChain = op;
    return op;
  }

  void _syncUsbMixerAttributesAndReopenIfNeeded({
    required OutputDevice device,
    required int sampleRate,
    required int bitDepth,
    required bool bitPerfect,
    required int currentOutputRate,
  }) {
    final bits = bitDepth > 0 ? bitDepth : 16;
    final key = (device.id, sampleRate, bits, bitPerfect);
    if (key == _lastMixerConfigKey ||
        key == _inFlightMixerKey ||
        key == _lastFailedMixerKey) {
      return;
    }
    if (bitPerfect &&
        _lastRejectedBitPerfectKey == (device.id, sampleRate, bits)) {
      return;
    }
    final previousKey = _lastMixerConfigKey;
    _inFlightMixerKey = key;

    _mixerUpdateChain = _mixerUpdateChain.then((_) async {
      try {
        final ok = await _outputProbe.setPreferredMixerAttributes(
          sampleRate: sampleRate,
          bitDepth: bits,
          bitPerfect: bitPerfect,
        );
        if (ok) {
          _lastMixerConfigKey = key;
          _lastFailedMixerKey = null;
          _lastRejectedBitPerfectKey = null;
          if (currentOutputRate != sampleRate ||
              (previousKey != null && previousKey.$4 != bitPerfect)) {
            try {
              rust.engineReopenOutputStream();
            } catch (_) {}
            recomputeSignalPath();
          }
        } else {
          _lastMixerConfigKey = null;
          _lastFailedMixerKey = key;
          if (bitPerfect) {
            _lastRejectedBitPerfectKey = (device.id, sampleRate, bits);
            recomputeSignalPath();
          }
        }
      } finally {
        if (_inFlightMixerKey == key) _inFlightMixerKey = null;
      }
    }).catchError((Object e) {
      debugPrint('[output] sync USB mixer failed: $e');
    });
  }

  static bool get _supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  static Codec _codecFromName(String name) => switch (name.toUpperCase()) {
        'FLAC' => Codec.flac,
        'ALAC' => Codec.alac,
        'PCM' || 'WAV' => Codec.wav,
        'AIFF' => Codec.aiff,
        'MP3' => Codec.mp3,
        'AAC' => Codec.aac,
        'VORBIS' || 'OPUS' => Codec.opus,
        'DSF' || 'DSD' => Codec.dsf,
        _ => Codec.flac,
      };

  static String _fmtKhz(int hz) {
    final khz = hz / 1000.0;
    return khz == khz.roundToDouble()
        ? '${khz.round()} kHz'
        : '${khz.toStringAsFixed(1)} kHz';
  }

  @visibleForTesting
  static String explainSignalPath(
    OutputTier tier,
    AudioFormat source,
    AudioFormat actual,
    bool dsp,
    OutputDevice? device, {
    bool isDirectUsb = false,
    bool engineSincResampled = false,
  }) =>
      _explain(
        tier,
        source,
        actual,
        dsp,
        device,
        isDirectUsb: isDirectUsb,
        engineSincResampled: engineSincResampled,
      );

  static String _explain(
    OutputTier tier,
    AudioFormat source,
    AudioFormat actual,
    bool dsp,
    OutputDevice? device, {
    bool isDirectUsb = false,
    bool engineSincResampled = false,
  }) {
    final srcRate = _fmtKhz(source.sampleRate);
    final outRate = _fmtKhz(actual.sampleRate);

    if (source.codec == Codec.dsf) {
      if (tier == OutputTier.bitPerfect) {
        if (isDirectUsb) {
          return 'Bit-perfect direct DSD stream active via User-Space USB Audio (Tier D) with DoP v1.1 framing. '
              'The audio engine transmits the pure 1-bit DSD bitstream directly to your ${device?.name ?? "USB DAC"} '
              'without PCM decimation, DSP, or OS mixer interaction.';
        }
        return 'DSD 1-bit stream decimated to 176.4 kHz / 24-bit PCM using 64-bit polyphase sinc FIR filter. '
            'Streaming bit-perfect PCM to ${device?.name ?? "USB DAC"} at 176.4 kHz with zero OS resampling.';
      }
      return 'DSD 1-bit stream decimated to 176.4 kHz / 24-bit PCM using 64-bit polyphase sinc FIR filter '
          'and routed to ${device?.name ?? "your audio device"}.';
    }

    if (tier == OutputTier.bitPerfect) {
      if (isDirectUsb) {
        return 'Bit-perfect direct stream active via User-Space USB Audio (Tier D). '
            'The audio engine has direct hardware control over your ${device?.name ?? "USB DAC"} at '
            '$outRate / ${actual.bitDepth}-bit format with zero OS mixer interaction or resampling.';
      }
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        return 'Bit-perfect direct stream active via iOS CoreAudio & AVAudioSession (Tier A). '
            'The audio engine has native hardware clock control over your ${device?.name ?? "USB DAC"} at '
            '$srcRate / ${source.bitDepth}-bit format with zero OS resampling or DSP.';
      }
      return 'Bit-perfect direct stream active via Android 14+ Mixer Attributes. '
          'The audio engine has exclusive access to your ${device?.name ?? "USB DAC"} at its native '
          '$srcRate / ${source.bitDepth}-bit format with zero resampling or DSP.';
    }
    if (dsp && actual.sampleRate == source.sampleRate) {
      return 'Audio is running at native $srcRate. '
          'The 64-bit floating-point equaliser or DSP is active, altering the audio samples. '
          'Bypass the equaliser to restore bit-perfect output.';
    }
    if (device?.type == DeviceType.phoneSpeaker) {
      final osName =
          defaultTargetPlatform == TargetPlatform.iOS ? 'iOS' : 'Android';
      if (actual.sampleRate != source.sampleRate) {
        return engineSincResampled
            ? 'Phone speakers run at $outRate via the $osName mixer; $srcRate audio is converted using BitDrop\'s 64-bit 256-tap Sinc resampler. Connect a USB DAC for bit-perfect playback.'
            : 'Phone speakers route through the $osName mixer at '
                '$outRate, so your $srcRate audio is resampled. Connect a USB DAC '
                'for bit-perfect playback.';
      } else {
        return 'Phone speaker output is routed through the $osName shared audio mixer at native '
            '$srcRate. Connect a USB DAC for direct exclusive bit-perfect playback.';
      }
    }
    if (device?.type == DeviceType.bluetooth) {
      final rateNote = actual.sampleRate != source.sampleRate && engineSincResampled
          ? ' ($srcRate converted via 64-bit 256-tap Sinc to $outRate).'
          : '';
      return 'Bluetooth re-encodes audio wirelessly with its codec (lossy compression)$rateNote, '
          'so bit-perfect playback is not possible over Bluetooth.';
    }
    if (tier == OutputTier.resampled &&
        actual.sampleRate != source.sampleRate) {
      final apiText = device?.apiLevel != null
          ? "Android ${device!.apiLevel}'s"
          : 'the Android';
      final devName = device?.name ?? 'your audio device';
      if (device?.type == DeviceType.usb) {
        return engineSincResampled
            ? '$apiText mixer for $devName runs at $outRate (converted from $srcRate via 64-bit 256-tap Sinc). Enable Direct USB access to stream $srcRate bit-perfect.'
            : '$apiText system mixer (AudioFlinger) mixes audio at $outRate, so your $srcRate file is resampled before reaching $devName. Enable Direct USB access to unlock bit-perfect output.';
      }
      if (engineSincResampled) {
        final jackNote = device?.type == DeviceType.wiredAnalog
            ? ' (3.5mm / wired analog jack)'
            : '';
        return '$devName$jackNote is locked to $apiText $outRate hardware mixer clock, so $srcRate audio is converted in-engine via BitDrop\'s 64-bit 256-tap Sinc resampler to avoid Android mixer distortion.';
      }
      return '$apiText system mixer (AudioFlinger) mixes audio at '
          '$outRate, so your $srcRate file is resampled before it reaches $devName. '
          'Connect a USB DAC for bit-perfect output.';
    }
    if (dsp) {
      return 'The equaliser or DSP is active, altering the audio samples. '
          'Bypass the equaliser to restore bit-perfect output.';
    }
    if (device != null && device.type == DeviceType.usb && !isDirectUsb) {
      final apiText = device.apiLevel != null
          ? "Android ${device.apiLevel}'s"
          : 'the Android';
      return 'Your ${device.name} is running at native $srcRate, '
          'routed through $apiText shared system mixer (AudioFlinger). '
          'Enable Direct USB access to bypass the mixer and unlock bit-perfect output.';
    }
    if (device != null && !device.supportsBitPerfect) {
      final apiText = device.apiLevel != null
          ? "Android ${device.apiLevel}'s"
          : 'the Android';
      return 'Your ${device.name} is running at native $srcRate, '
          'routed through $apiText system mixer (AudioFlinger).';
    }
    if (tier == OutputTier.nativeRate) {
      return "No resampling is happening: the stream runs at the file's native rate "
          '($srcRate).';
    }
    return 'The output path could not be determined.';
  }

  void dispose() {
    _outputProbeSub?.cancel();
    _signalPath.close();
  }
}
