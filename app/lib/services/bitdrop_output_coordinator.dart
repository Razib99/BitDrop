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

  VoidCallback? onEarphoneDisconnected;
  VoidCallback? onBecomingNoisy;
  VoidCallback? onInterruptionBegan;
  ValueChanged<bool>? onInterruptionEnded;
  VoidCallback? onDirectUsbAutoAttachNeeded;

  Track? Function()? currentTrackProvider;
  CloudLibrary? Function()? cloudProvider;
  bool Function()? isDirectUsbDriverEnabled;
  EqState? Function()? eqStateProvider;

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
    this.currentTrackProvider,
    this.cloudProvider,
    this.isDirectUsbDriverEnabled,
    this.eqStateProvider,
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
      final newType = device?.type;
      final wasEarphone = isEarphone(previousType);
      final isNowEarphone = isEarphone(newType);

      if (wasEarphone && !isNowEarphone) {
        onEarphoneDisconnected?.call();
      }

      if (isDirectUsbDriverEnabled?.call() == true &&
          newType == DeviceType.usb) {
        if (onDirectUsbAutoAttachNeeded != null) {
          onDirectUsbAutoAttachNeeded!();
        } else {
          unawaited(autoAttachDirectUsbIfPossible());
        }
      }
      previousType = newType;
      recomputeSignalPath();
    });

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
      recomputeSignalPath();
    };
  }

  Future<void> autoAttachDirectUsbIfPossible() async {
    try {
      final backend = _outputProbe.getStreamBackend();
      if (backend == 'DirectUsb') return;
      final usbDevices = await _outputProbe.listUsbAudioDevices();
      if (usbDevices.isNotEmpty) {
        final dev = usbDevices.first;
        if (dev.hasPermission) {
          await _outputProbe.attachDirectUsbDac(deviceId: dev.deviceId);
          recomputeSignalPath();
        }
      }
    } catch (_) {}
  }

  Future<void> handleDirectUsbDriverSetting(bool enabled) async {
    if (!enabled) {
      await _outputProbe.detachDirectUsbDac();
      recomputeSignalPath();
      return;
    }
    try {
      final usbDevices = await _outputProbe.listUsbAudioDevices();
      if (usbDevices.isNotEmpty) {
        final targetDev = usbDevices.first;
        if (!targetDev.hasPermission) {
          final granted =
              await _outputProbe.requestUsbPermission(targetDev.deviceId);
          if (!granted) {
            debugPrint(
              '[usb] Permission denied for direct USB device ${targetDev.deviceId}',
            );
            return;
          }
        }
        await _outputProbe.attachDirectUsbDac(deviceId: targetDev.deviceId);
        recomputeSignalPath();
      }
    } catch (e) {
      debugPrint('[usb] Failed to engage direct USB DAC: $e');
    }
  }

  void recomputeSignalPath() {
    if (_signalPath.isClosed) return;
    final rust.EngineOutputState out;
    try {
      out = rust.engineOutputState();
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

    final dsp = out.dspActive;
    final isExclusiveBitPerfect = isDirectUsb ||
        ((device?.type == DeviceType.usb &&
                device?.supportsBitPerfect == true) &&
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
      tier = OutputTier.bitPerfect;
    } else if (isRateShifted) {
      tier = OutputTier.resampled;
    } else if (isExclusiveBitPerfect) {
      tier = OutputTier.bitPerfect;
    } else {
      tier = OutputTier.nativeRate;
    }

    if (device?.type == DeviceType.usb && _supported && !isDirectUsb) {
      unawaited(_outputProbe.setPreferredMixerAttributes(
        sampleRate: source.sampleRate,
        bitDepth: source.bitDepth,
        bitPerfect: !dsp,
      ));
    }

    final eqState = eqStateProvider?.call();
    final dspChain = eqState != null
        ? BitDropSettingsRepository.describeDspChain(eqState, engineDspActive: dsp)
        : (dsp ? const ['Equaliser'] : const <String>[]);

    final cloud = cloudProvider?.call();
    final currentTrackId = track?.id ?? '';

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
      explanation:
          _explain(tier, source, actual, dsp, device, isDirectUsb: isDirectUsb),
    ));
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

  static String _explain(
    OutputTier tier,
    AudioFormat source,
    AudioFormat actual,
    bool dsp,
    OutputDevice? device, {
    bool isDirectUsb = false,
  }) {
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
            '${actual.sampleRate ~/ 1000} kHz / ${actual.bitDepth}-bit format with zero OS mixer interaction or resampling.';
      }
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        return 'Bit-perfect direct stream active via iOS CoreAudio & AVAudioSession (Tier A). '
            'The audio engine has native hardware clock control over your ${device?.name ?? "USB DAC"} at '
            '${source.sampleRate ~/ 1000} kHz / ${source.bitDepth}-bit format with zero OS resampling or DSP.';
      }
      return 'Bit-perfect direct stream active via Android 14+ Mixer Attributes. '
          'The audio engine has exclusive access to your ${device?.name ?? "USB DAC"} at its native '
          '${source.sampleRate ~/ 1000} kHz / ${source.bitDepth}-bit format with zero resampling or DSP.';
    }
    if (dsp && actual.sampleRate == source.sampleRate) {
      return 'Audio is running at native ${source.sampleRate ~/ 1000} kHz. '
          'The 64-bit floating-point equaliser or DSP is active, altering the audio samples. '
          'Bypass the equaliser to restore bit-perfect output.';
    }
    if (device?.type == DeviceType.phoneSpeaker) {
      final osName =
          defaultTargetPlatform == TargetPlatform.iOS ? 'iOS' : 'Android';
      if (actual.sampleRate != source.sampleRate) {
        return 'Phone speakers route through the $osName mixer at '
            '${actual.sampleRate ~/ 1000} kHz, so your '
            '${source.sampleRate ~/ 1000} kHz audio is resampled. Connect a USB DAC '
            'for bit-perfect playback.';
      } else {
        return 'Phone speaker output is routed through the $osName shared audio mixer at native '
            '${source.sampleRate ~/ 1000} kHz. Connect a USB DAC for direct exclusive bit-perfect playback.';
      }
    }
    if (device?.type == DeviceType.bluetooth) {
      return 'Bluetooth re-encodes audio with its own codec (lossy compression), '
          'so lossless bit-perfect playback is not possible over Bluetooth.';
    }
    if (tier == OutputTier.resampled &&
        actual.sampleRate != source.sampleRate) {
      final apiText = device?.apiLevel != null
          ? "Android ${device!.apiLevel}'s"
          : 'the Android';
      final devName = device?.name ?? 'your audio device';
      return '$apiText system mixer (AudioFlinger) mixes audio at '
          '${actual.sampleRate ~/ 1000} kHz, so your '
          '${source.sampleRate ~/ 1000} kHz file is resampled before it reaches $devName. '
          'Connect a USB DAC for bit-perfect playback.';
    }
    return 'Audio is routed to ${device?.name ?? "your audio device"} at '
        'native rate ${actual.sampleRate ~/ 1000} kHz.';
  }

  void dispose() {
    _outputProbeSub?.cancel();
    _signalPath.close();
  }
}
