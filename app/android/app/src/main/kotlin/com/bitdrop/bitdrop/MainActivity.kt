package com.bitdrop.bitdrop

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioMixerAttributes
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.annotation.RequiresApi
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {

    private val channelName = "com.bitdrop/audio_device"
    private var methodChannel: MethodChannel? = null
    private var noisyReceiver: BroadcastReceiver? = null
    private var audioDeviceCallback: AudioDeviceCallback? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        methodChannel = channel

        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "currentOutput" -> result.success(currentOutput())
                "getMixerAttributes" -> result.success(getMixerAttributes())
                "setPreferredMixerAttributes" -> {
                    val sampleRate = call.argument<Int>("sampleRate") ?: 44100
                    val bitDepth = call.argument<Int>("bitDepth") ?: 16
                    val bitPerfect = call.argument<Boolean>("bitPerfect") ?: true
                    result.success(setPreferredMixerAttributes(sampleRate, bitDepth, bitPerfect))
                }
                "clearPreferredMixerAttributes" -> {
                    result.success(clearPreferredMixerAttributes())
                }
                else -> result.notImplemented()
            }
        }

        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager

        // Real-time audio device connection / disconnection monitoring
        val deviceCallback = object : AudioDeviceCallback() {
            override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>?) {
                runOnUiThread {
                    methodChannel?.invokeMethod("onDeviceChanged", null)
                }
            }
            override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>?) {
                runOnUiThread {
                    methodChannel?.invokeMethod("onDeviceChanged", null)
                }
            }
        }
        audioDeviceCallback = deviceCallback
        am.registerAudioDeviceCallback(deviceCallback, Handler(Looper.getMainLooper()))

        // Broadcast receiver for ACTION_AUDIO_BECOMING_NOISY (unplugging earphones/headphones)
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (AudioManager.ACTION_AUDIO_BECOMING_NOISY == intent?.action) {
                    runOnUiThread {
                        methodChannel?.invokeMethod("onBecomingNoisy", null)
                    }
                }
            }
        }
        noisyReceiver = receiver
        val filter = IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
        } else {
            registerReceiver(receiver, filter)
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        super.cleanUpFlutterEngine(flutterEngine)
        val am = getSystemService(Context.AUDIO_SERVICE) as? AudioManager
        audioDeviceCallback?.let {
            am?.unregisterAudioDeviceCallback(it)
        }
        audioDeviceCallback = null

        noisyReceiver?.let {
            try {
                unregisterReceiver(it)
            } catch (_: Exception) {}
        }
        noisyReceiver = null
        methodChannel = null
    }

    override fun onDestroy() {
        super.onDestroy()
        val am = getSystemService(Context.AUDIO_SERVICE) as? AudioManager
        audioDeviceCallback?.let {
            am?.unregisterAudioDeviceCallback(it)
        }
        audioDeviceCallback = null

        noisyReceiver?.let {
            try {
                unregisterReceiver(it)
            } catch (_: Exception) {}
        }
        noisyReceiver = null
        methodChannel = null
    }

    private fun getActiveUsbDevice(am: AudioManager): AudioDeviceInfo? {
        val devices = am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
        return devices.firstOrNull {
            it.type == AudioDeviceInfo.TYPE_USB_DEVICE ||
            it.type == AudioDeviceInfo.TYPE_USB_HEADSET ||
            it.type == AudioDeviceInfo.TYPE_USB_ACCESSORY
        }
    }

    private val mediaAudioAttributes: AudioAttributes by lazy {
        AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
            .build()
    }

    /**
     * The output device audio is actually routed to, with verified platform capabilities.
     */
    private fun currentOutput(): Map<String, Any?> {
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val devices = am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)

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

        val isUsb = active.type == AudioDeviceInfo.TYPE_USB_DEVICE ||
                    active.type == AudioDeviceInfo.TYPE_USB_HEADSET ||
                    active.type == AudioDeviceInfo.TYPE_USB_ACCESSORY

        var supportsBitPerfect = false
        var maxTier = when (typeName(active.type)) {
            "bluetooth", "speaker" -> "resampled"
            "wired" -> "nativeRate"
            else -> "unknown"
        }
        var tierExplanation = ""

        if (isUsb) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                try {
                    val attrs = am.getSupportedMixerAttributes(active)
                    val hasBp = attrs.any { it.mixerBehavior == AudioMixerAttributes.MIXER_BEHAVIOR_BIT_PERFECT }
                    supportsBitPerfect = hasBp
                    if (hasBp) {
                        maxTier = "bitPerfect"
                        tierExplanation = "Android 14+ Bit-Perfect mixer attributes supported for this USB DAC."
                    } else if (attrs.isNotEmpty()) {
                        maxTier = "nativeRate"
                        tierExplanation = "Android 14+ mixer attributes available but restricted to default mixer behavior."
                    } else {
                        maxTier = "resampled"
                        tierExplanation = "USB DAC does not advertise specialized mixer attributes."
                    }
                } catch (e: Exception) {
                    maxTier = "nativeRate"
                    tierExplanation = "Could not query mixer attributes: ${e.message}"
                }
            } else {
                supportsBitPerfect = false
                maxTier = "nativeRate"
                tierExplanation = "Android ${Build.VERSION.SDK_INT} (pre-Android 14) routes audio through AudioFlinger mixer."
            }
        }

        return mapOf(
            "available" to true,
            "name" to (active.productName?.toString()?.trim().orEmpty()),
            "type" to typeName(active.type),
            "sampleRates" to active.sampleRates.toList(),
            "channelCounts" to active.channelCounts.toList(),
            "encodings" to active.encodings.toList(),
            "apiLevel" to Build.VERSION.SDK_INT,
            "isUsb" to isUsb,
            "supportsBitPerfect" to supportsBitPerfect,
            "maxTier" to maxTier,
            "tierExplanation" to tierExplanation,
        )
    }

    private fun getMixerAttributes(): Map<String, Any?> {
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val usbDevice = getActiveUsbDevice(am)
        val apiLevel = Build.VERSION.SDK_INT

        if (usbDevice == null) {
            return mapOf(
                "apiLevel" to apiLevel,
                "hasUsb" to false,
                "supportsBitPerfect" to false,
                "tier" to "C",
                "tierExplanation" to "No USB DAC connected. Resampled by system AudioFlinger.",
                "supportedFormats" to emptyList<Map<String, Any>>()
            )
        }

        if (apiLevel < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            return mapOf(
                "apiLevel" to apiLevel,
                "hasUsb" to true,
                "deviceName" to (usbDevice.productName?.toString() ?: "USB Device"),
                "supportsBitPerfect" to false,
                "tier" to "C",
                "tierExplanation" to "Android $apiLevel (pre-Android 14) cannot bypass Fast Mixer without root. Resampled to 48 kHz by AudioFlinger.",
                "supportedFormats" to emptyList<Map<String, Any>>()
            )
        }

        return getApi34MixerAttributes(am, usbDevice)
    }

    @RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
    private fun getApi34MixerAttributes(am: AudioManager, device: AudioDeviceInfo): Map<String, Any?> {
        val attrsList = try {
            am.getSupportedMixerAttributes(device)
        } catch (e: Exception) {
            emptyList<AudioMixerAttributes>()
        }

        val hasBitPerfect = attrsList.any { it.mixerBehavior == AudioMixerAttributes.MIXER_BEHAVIOR_BIT_PERFECT }
        val formats = attrsList.map { attr ->
            val fmt = attr.format
            mapOf(
                "sampleRate" to fmt.sampleRate,
                "channelMask" to fmt.channelMask,
                "encoding" to fmt.encoding,
                "isBitPerfect" to (attr.mixerBehavior == AudioMixerAttributes.MIXER_BEHAVIOR_BIT_PERFECT)
            )
        }

        val tier = if (hasBitPerfect) "A" else "B"
        val explanation = if (hasBitPerfect) {
            "Tier A: Android 14+ Bit-Perfect mixer available for USB DAC."
        } else {
            "Tier B: Android 14+ mixer attributes available but restricted to default mixer behavior."
        }

        return mapOf(
            "apiLevel" to Build.VERSION.SDK_INT,
            "hasUsb" to true,
            "deviceName" to (device.productName?.toString() ?: "USB Device"),
            "supportsBitPerfect" to hasBitPerfect,
            "tier" to tier,
            "tierExplanation" to explanation,
            "supportedFormats" to formats
        )
    }

    private fun setPreferredMixerAttributes(sampleRate: Int, bitDepth: Int, bitPerfect: Boolean): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            return false
        }
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val usbDevice = getActiveUsbDevice(am) ?: return false

        return setApi34PreferredMixerAttributes(am, usbDevice, sampleRate, bitDepth, bitPerfect)
    }

    @RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
    private fun setApi34PreferredMixerAttributes(
        am: AudioManager,
        device: AudioDeviceInfo,
        sampleRate: Int,
        bitDepth: Int,
        bitPerfect: Boolean
    ): Boolean {
        return try {
            val encoding = when (bitDepth) {
                24 -> AudioFormat.ENCODING_PCM_24BIT_PACKED
                32 -> AudioFormat.ENCODING_PCM_32BIT
                else -> AudioFormat.ENCODING_PCM_16BIT
            }

            val format = AudioFormat.Builder()
                .setSampleRate(sampleRate)
                .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                .setEncoding(encoding)
                .build()

            val behavior = if (bitPerfect) {
                AudioMixerAttributes.MIXER_BEHAVIOR_BIT_PERFECT
            } else {
                AudioMixerAttributes.MIXER_BEHAVIOR_DEFAULT
            }

            val mixerAttrs = AudioMixerAttributes.Builder(format)
                .setMixerBehavior(behavior)
                .build()

            am.setPreferredMixerAttributes(mediaAudioAttributes, device, mixerAttrs)
        } catch (e: Exception) {
            false
        }
    }

    private fun clearPreferredMixerAttributes(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            return false
        }
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val usbDevice = getActiveUsbDevice(am) ?: return false

        return try {
            am.clearPreferredMixerAttributes(mediaAudioAttributes, usbDevice)
        } catch (e: Exception) {
            false
        }
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
