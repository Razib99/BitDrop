package com.bitdrop.bitdrop

import com.ryanheise.audioservice.AudioServiceActivity

// audio_service requires the launcher activity to extend AudioServiceActivity:
// it hands the plugin the FlutterEngine the background service shares. With a
// plain FlutterActivity, AudioService.init() throws and, because that happens
// in main() before runApp(), the app shows nothing at all.
class MainActivity : AudioServiceActivity()
