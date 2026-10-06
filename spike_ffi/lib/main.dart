import 'package:flutter/material.dart';
import 'package:spike_ffi/src/rust/api/simple.dart';
import 'package:spike_ffi/src/rust/frb_generated.dart';

Future<void> main() async {
  await RustLib.init();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Rust FFI + Symphonia FLAC Probe')),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text('Audio Decoder Spike', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 24)),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: () {
                  try {
                    // We pass an empty/invalid byte array just to prove the FFI bridge connects to Symphonia
                    final metadata = getFlacMetadata(audioData: [0x66, 0x4C, 0x61, 0x43]); 
                    print('Channels: ${metadata.channels}, SR: ${metadata.sampleRate}');
                  } catch (e) {
                    print('Rust Error (expected, bad FLAC bytes): $e');
                  }
                },
                child: const Text('Test FLAC Decode (See Console)'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
