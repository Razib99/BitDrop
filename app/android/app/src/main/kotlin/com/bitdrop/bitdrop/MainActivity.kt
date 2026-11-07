package com.bitdrop.bitdrop

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbManager
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

    private var activeUsbConnection: UsbDeviceConnection? = null
    private var activeUsbDevice: UsbDevice? = null
    private var usbPermissionReceiver: BroadcastReceiver? = null
    private var usbDetachReceiver: BroadcastReceiver? = null
    private val ACTION_USB_PERMISSION = "com.bitdrop.bitdrop.USB_PERMISSION"

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
                "listUsbAudioDevices" -> result.success(listUsbAudioDevices())
                "requestUsbPermission" -> {
                    val deviceId = call.argument<Int>("deviceId") ?: -1
                    requestUsbPermission(deviceId, result)
                }
                "openUsbDevice" -> {
                    val deviceId = call.argument<Int>("deviceId") ?: -1
                    openUsbDevice(deviceId, result)
                }
                "closeUsbDevice" -> result.success(closeUsbDevice())
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

        // Real-time USB device detachment monitoring
        val detachReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (UsbManager.ACTION_USB_DEVICE_DETACHED == intent?.action) {
                    val device: UsbDevice? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        intent.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
                    } else {
                        @Suppress("DEPRECATION")
                        intent.getParcelableExtra(UsbManager.EXTRA_DEVICE)
                    }
                    if (device != null && device.deviceId == activeUsbDevice?.deviceId) {
                        closeUsbDevice()
                    }
                    runOnUiThread {
                        methodChannel?.invokeMethod("onUsbDeviceDetached", device?.deviceId)
                        methodChannel?.invokeMethod("onDeviceChanged", null)
                    }
                }
            }
        }
        usbDetachReceiver = detachReceiver
        val detachFilter = IntentFilter(UsbManager.ACTION_USB_DEVICE_DETACHED)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(detachReceiver, detachFilter, Context.RECEIVER_EXPORTED)
        } else {
            registerReceiver(detachReceiver, detachFilter)
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

        usbDetachReceiver?.let {
            try {
                unregisterReceiver(it)
            } catch (_: Exception) {}
        }
        usbDetachReceiver = null

        usbPermissionReceiver?.let {
            try {
                unregisterReceiver(it)
            } catch (_: Exception) {}
        }
        usbPermissionReceiver = null

        closeUsbDevice()
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

        usbDetachReceiver?.let {
            try {
                unregisterReceiver(it)
            } catch (_: Exception) {}
        }
        usbDetachReceiver = null

        usbPermissionReceiver?.let {
            try {
                unregisterReceiver(it)
            } catch (_: Exception) {}
        }
        usbPermissionReceiver = null

        closeUsbDevice()
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

        val systemSampleRate = am.getProperty(AudioManager.PROPERTY_OUTPUT_SAMPLE_RATE)?.toIntOrNull() ?: 48000

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
            "systemSampleRate" to systemSampleRate,
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

    private fun isUsbAudioDevice(device: UsbDevice): Boolean {
        if (device.deviceClass == UsbConstants.USB_CLASS_AUDIO) return true
        for (i in 0 until device.interfaceCount) {
            val iface = device.getInterface(i)
            if (iface.interfaceClass == UsbConstants.USB_CLASS_AUDIO) {
                return true
            }
        }
        return false
    }

    private fun listUsbAudioDevices(): List<Map<String, Any?>> {
        val usbManager = getSystemService(Context.USB_SERVICE) as? UsbManager ?: return emptyList()
        val devices = usbManager.deviceList.values.filter { isUsbAudioDevice(it) }
        return devices.map { d ->
            mapOf(
                "deviceId" to d.deviceId,
                "deviceName" to d.deviceName,
                "productName" to (d.productName?.trim() ?: "USB Audio Device"),
                "manufacturerName" to (d.manufacturerName?.trim() ?: "Unknown"),
                "vendorId" to d.vendorId,
                "productId" to d.productId,
                "hasPermission" to usbManager.hasPermission(d)
            )
        }
    }

    private fun requestUsbPermission(deviceId: Int, result: MethodChannel.Result) {
        val usbManager = getSystemService(Context.USB_SERVICE) as? UsbManager
        if (usbManager == null) {
            result.error("USB_UNAVAILABLE", "USB Manager not available", null)
            return
        }
        val device = usbManager.deviceList.values.firstOrNull { it.deviceId == deviceId }
        if (device == null) {
            result.error("DEVICE_NOT_FOUND", "USB device $deviceId not found", null)
            return
        }
        if (usbManager.hasPermission(device)) {
            result.success(true)
            return
        }

        usbPermissionReceiver?.let {
            try {
                unregisterReceiver(it)
            } catch (_: Exception) {}
        }

        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        val intent = Intent(ACTION_USB_PERMISSION)
        intent.setPackage(packageName)
        val pendingIntent = PendingIntent.getBroadcast(this, deviceId, intent, flags)

        val permReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (ACTION_USB_PERMISSION == intent?.action) {
                    val dev: UsbDevice? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        intent.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
                    } else {
                        @Suppress("DEPRECATION")
                        intent.getParcelableExtra(UsbManager.EXTRA_DEVICE)
                    }
                    val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                    try {
                        unregisterReceiver(this)
                    } catch (_: Exception) {}
                    usbPermissionReceiver = null
                    runOnUiThread {
                        result.success(granted)
                    }
                }
            }
        }
        usbPermissionReceiver = permReceiver
        val filter = IntentFilter(ACTION_USB_PERMISSION)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(permReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(permReceiver, filter)
        }
        usbManager.requestPermission(device, pendingIntent)
    }

    private fun openUsbDevice(deviceId: Int, result: MethodChannel.Result) {
        val usbManager = getSystemService(Context.USB_SERVICE) as? UsbManager
        if (usbManager == null) {
            result.error("USB_UNAVAILABLE", "USB Manager not available", null)
            return
        }
        val device = usbManager.deviceList.values.firstOrNull { it.deviceId == deviceId }
        if (device == null) {
            result.error("DEVICE_NOT_FOUND", "USB device $deviceId not found", null)
            return
        }
        if (!usbManager.hasPermission(device)) {
            result.error("PERMISSION_DENIED", "Permission not granted for USB device $deviceId", null)
            return
        }

        closeUsbDevice()

        val connection = usbManager.openDevice(device)
        if (connection == null) {
            result.error("OPEN_FAILED", "Could not open USB connection for device $deviceId", null)
            return
        }

        activeUsbConnection = connection
        activeUsbDevice = device
        val fd = connection.fileDescriptor

        result.success(
            mapOf(
                "fd" to fd,
                "deviceId" to device.deviceId,
                "vendorId" to device.vendorId,
                "productId" to device.productId,
                "productName" to (device.productName?.trim() ?: "USB Audio Device"),
                "manufacturerName" to (device.manufacturerName?.trim() ?: "Unknown")
            )
        )
    }

    private fun closeUsbDevice(): Boolean {
        activeUsbConnection?.let {
            try {
                it.close()
            } catch (_: Exception) {}
        }
        activeUsbConnection = null
        activeUsbDevice = null
        return true
    }
}
