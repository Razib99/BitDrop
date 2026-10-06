import 'package:bitdrop/core_api/enums.dart';
import 'package:bitdrop/core_api/models.dart';
import 'package:bitdrop/util/biquad.dart';
import 'package:bitdrop/util/format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Fmt', () {
    test('durations', () {
      expect(Fmt.duration(0), '0:00');
      expect(Fmt.duration(41000), '0:41');
      expect(Fmt.duration(221000), '3:41');
      expect(Fmt.duration(3734000), '1:02:14');
      expect(Fmt.duration(-500), '0:00');
    });

    test('dB uses a true minus sign', () {
      expect(Fmt.db(-6.2), '−6.2 dB');
      expect(Fmt.db(0), '0.0 dB');
      expect(Fmt.db(1.5), '+1.5 dB');
    });

    test('sample rates drop a trailing zero', () {
      expect(Fmt.kHz(96000), '96 kHz');
      expect(Fmt.kHz(44100), '44.1 kHz');
      expect(Fmt.kHz(192000), '192 kHz');
    });

    test('byte sizes use decimal units', () {
      expect(Fmt.bytes(999), '999 B');
      expect(Fmt.bytes(1500), '1.50 kB');
      expect(Fmt.bytes(1420000000), '1.42 GB');
    });

    test('counts are grouped', () {
      expect(Fmt.count(12480), '12,480');
      expect(Fmt.count(812), '812');
    });
  });

  group('AudioFormat', () {
    test('classifies quality', () {
      const hiRes =
          AudioFormat(codec: Codec.flac, bitDepth: 24, sampleRate: 96000);
      const cd =
          AudioFormat(codec: Codec.flac, bitDepth: 16, sampleRate: 44100);
      const lossy =
          AudioFormat(codec: Codec.mp3, bitDepth: 16, sampleRate: 44100);

      expect(hiRes.isHiRes, isTrue);
      expect(cd.isHiRes, isFalse);
      expect(cd.isCdQuality, isTrue);
      expect(lossy.codec.isLossless, isFalse);
      expect(hiRes.shortLabel, '24/96');
      expect(cd.shortLabel, '16/44.1');
    });

    test('unsupported codecs are flagged, not hidden', () {
      expect(Codec.ape.isSupported, isFalse);
      expect(Codec.dsf.isSupported, isFalse);
      expect(Codec.opus.isSupported, isFalse);
      expect(Codec.flac.isSupported, isTrue);
    });
  });

  group('Biquad', () {
    test('a flat band contributes nothing', () {
      const band = EqBand(
          id: 1, type: BiquadType.peak, frequencyHz: 1000, gainDb: 0, q: 1);
      expect(Biquad.magnitudeDb(band, 1000), closeTo(0, 0.01));
    });

    test('a peaking band hits its gain at centre frequency', () {
      const band = EqBand(
          id: 1, type: BiquadType.peak, frequencyHz: 1000, gainDb: 6, q: 1);
      expect(Biquad.magnitudeDb(band, 1000), closeTo(6, 0.1));
      // ...and leaves the far ends alone.
      expect(Biquad.magnitudeDb(band, 30), closeTo(0, 0.5));
    });

    test('a disabled band is ignored', () {
      const band = EqBand(
        id: 1,
        type: BiquadType.peak,
        frequencyHz: 1000,
        gainDb: 12,
        q: 1,
        enabled: false,
      );
      expect(Biquad.magnitudeDb(band, 1000), 0);
    });

    test('the suggested preamp cancels the curve peak', () {
      const bands = [
        EqBand(
            id: 1, type: BiquadType.peak, frequencyHz: 100, gainDb: 6, q: 1),
        EqBand(
            id: 2, type: BiquadType.peak, frequencyHz: 5000, gainDb: 3, q: 2),
      ];
      final preamp = Biquad.suggestedPreamp(bands);
      expect(preamp, lessThan(0));
      expect(Biquad.peakDb(bands, preampDb: preamp), lessThanOrEqualTo(0.05));
    });

    test('the log axis maps endpoints exactly', () {
      expect(Biquad.logFrequencyAt(0), closeTo(20, 0.001));
      expect(Biquad.logFrequencyAt(1), closeTo(20000, 0.001));
      expect(Biquad.positionOf(20), 0);
      expect(Biquad.positionOf(20000), 1);
    });
  });
}
