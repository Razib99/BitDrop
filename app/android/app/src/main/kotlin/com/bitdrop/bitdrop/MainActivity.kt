package com.bitdrop.bitdrop

import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioManager
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// audio_service requires the launcher activity to extend AudioServiceActivity:
// it hands the plugin the FlutterEngine the background service shares. With a
// plain FlutterActivity, AudioService.init() throws and, because that happens
// in main() before runApp(), the app shows nothing at all.
class MainActivity : AudioServiceActivity() {

    private val channel = "com.bitdrop/audio_device"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "currentOutput" -> result.success(currentOutput())
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * The output device audio is actually routed to, with what it can do.
     *
     * BitDrop's whole premise is not claiming a quality it has not verified,
     * so this reports only what AudioManager states. Anything unknown is
     * returned as unknown rather than guessed at.
     */
    private fun currentOutput(): Map<String, Any?> {
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val devices = am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)

        // Routing preference, best first: a USB DAC or headset is a
        // deliberate choice by the user, the speaker is the fallback.
        val order = listOf(
            AudioDeviceInfo.TYPE_USB_HEADSET,
            AudioDeviceInfo.TYPE_USB_DEVICE,
            AudioDeviceInfo.TYPE_USB_ACCESSORY,
            AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
            AudioDeviceInfo.TYPE_WIRED_HEADSET,
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
            AudioDeviceInfo.TYPE_BUILTIN_SPEAKER,
        )

        val active = order.firstNotNullOfOrNull { wanted ->
            devices.firstOrNull { it.type == wanted }
        } ?: devices.firstOrNull()

        if (active == null) return mapOf("available" to false)

        return mapOf(
            "available" to true,
            "name" to (active.productName?.toString()?.trim().orEmpty()),
            "type" to typeName(active.type),
            // Empty lists mean "the device did not say", which the UI shows
            // as unknown instead of inventing a capability.
            "sampleRates" to active.sampleRates.toList(),
            "channelCounts" to active.channelCounts.toList(),
            "encodings" to active.encodings.toList(),
        )
    }

    private fun typeName(type: Int): String = when (type) {
        AudioDeviceInfo.TYPE_USB_HEADSET,
        AudioDeviceInfo.TYPE_USB_DEVICE,
        AudioDeviceInfo.TYPE_USB_ACCESSORY -> "usb"
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
        AudioDeviceInfo.TYPE_WIRED_HEADSET -> "wired"
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> "bluetooth"
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "speaker"
        else -> "unknown"
    }
}
