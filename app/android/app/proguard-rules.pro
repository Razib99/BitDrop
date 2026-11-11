# BitDrop ProGuard / R8 Release Keep Rules
# Ensures JNI/FFI entrypoints, Android hardware HAL reflection, and background media receivers
# are preserved during release minification (isMinifyEnabled = true).

# 1. Flutter Rust Bridge & JNI Native Boundaries
-keep class com.bitdrop.** { *; }
-keep class * implements io.flutter.plugin.common.MethodChannel$MethodCallHandler { *; }
-keep class * implements io.flutter.plugin.common.EventChannel$StreamHandler { *; }
-keepclasseswithmembernames class * {
    native <methods>;
}

# 2. Android 14+ AudioMixerAttributes (API 34) & HAL Reflection
-keep class android.media.AudioMixerAttributes { *; }
-keep class android.media.AudioMixerAttributes$Builder { *; }
-keep class android.media.AudioFormat { *; }
-keep class android.media.AudioTrack { *; }
-keep class android.media.AudioManager { *; }

# 3. Direct Linux USBFS & Android UsbManager Subsystem
-keep class android.hardware.usb.UsbManager { *; }
-keep class android.hardware.usb.UsbDeviceConnection { *; }
-keep class android.hardware.usb.UsbDevice { *; }
-keep class android.hardware.usb.UsbInterface { *; }
-keep class android.hardware.usb.UsbEndpoint { *; }

# 4. Media3 & AudioService Background Notification Receivers
-keep class androidx.media3.** { *; }
-keep class com.ryanheise.audioservice.** { *; }
-dontwarn androidx.media3.**
-dontwarn com.ryanheise.audioservice.**

# 5. Flutter Engine & Obfuscation Compatibility
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }

# 6. Google Play Core & Deferred Components (optional dependencies)
-dontwarn com.google.android.play.core.**
