package com.bitdrop.bitdrop

import android.Manifest
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
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
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.storage.StorageManager
import android.provider.MediaStore
import android.provider.Settings
import java.io.File
import androidx.annotation.RequiresApi
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {

    private val channelName = "com.bitdrop/audio_device"
    private val storageChannelName = "com.bitdrop/local_storage"
    private var methodChannel: MethodChannel? = null
    private var storageChannel: MethodChannel? = null
    private var pendingAudioPermissionResult: MethodChannel.Result? = null
    private var noisyReceiver: BroadcastReceiver? = null
    private var audioDeviceCallback: AudioDeviceCallback? = null

    private var activeUsbConnection: UsbDeviceConnection? = null
    private var activeUsbDevice: UsbDevice? = null
    private var usbPermissionReceiver: BroadcastReceiver? = null
    private var pendingUsbPermissionResult: MethodChannel.Result? = null
    private var usbAttachReceiver: BroadcastReceiver? = null
    private var usbDetachReceiver: BroadcastReceiver? = null
    private val ACTION_USB_PERMISSION = "com.bitdrop.bitdrop.USB_PERMISSION"
    private val REQ_CODE_AUDIO_PERMISSION = 4201
    private val PREFS_PERMISSIONS = "bitdrop_permissions"
    private val KEY_ASKED_AUDIO_PERM = "asked_audio_permission"

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

        val localStorageChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, storageChannelName)
        storageChannel = localStorageChannel
        localStorageChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getAudioPermissionStatus" -> result.success(getAudioPermissionStatus())
                "requestAudioPermission" -> requestAudioPermission(result)
                "openAppSettings" -> result.success(openAppSettings())
                "discoverMusicDirectories" -> result.success(discoverMusicDirectories())
                else -> result.notImplemented()
            }
        }

        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager

        // Clean up any prior registrations if configureFlutterEngine is re-entered.
        unregisterAudioAndUsbReceivers()

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
            registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(receiver, filter)
        }

        // Real-time USB device attachment monitoring
        val attachReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (UsbManager.ACTION_USB_DEVICE_ATTACHED == intent?.action) {
                    val device: UsbDevice? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        intent.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
                    } else {
                        @Suppress("DEPRECATION")
                        intent.getParcelableExtra(UsbManager.EXTRA_DEVICE)
                    }
                    if (device != null && isUsbAudioDevice(device)) {
                        runOnUiThread {
                            methodChannel?.invokeMethod("onDeviceChanged", null)
                        }
                    }
                }
            }
        }
        usbAttachReceiver = attachReceiver
        val attachFilter = IntentFilter(UsbManager.ACTION_USB_DEVICE_ATTACHED)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(attachReceiver, attachFilter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(attachReceiver, attachFilter)
        }

        // Real-time USB device detachment monitoring (filtered to USB audio / active DAC)
        val detachReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (UsbManager.ACTION_USB_DEVICE_DETACHED == intent?.action) {
                    val device: UsbDevice? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        intent.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
                    } else {
                        @Suppress("DEPRECATION")
                        intent.getParcelableExtra(UsbManager.EXTRA_DEVICE)
                    }
                    val isActive = device != null && device.deviceId == activeUsbDevice?.deviceId
                    val isAudio = device != null && isUsbAudioDevice(device)
                    if (!isActive && !isAudio) {
                        return
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
            registerReceiver(detachReceiver, detachFilter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(detachReceiver, detachFilter)
        }
    }

    private fun unregisterAudioAndUsbReceivers() {
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

        usbAttachReceiver?.let {
            try {
                unregisterReceiver(it)
            } catch (_: Exception) {}
        }
        usbAttachReceiver = null

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
        pendingUsbPermissionResult?.let { pending ->
            try {
                pending.success(false)
            } catch (_: Exception) {}
        }
        pendingUsbPermissionResult = null
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        super.cleanUpFlutterEngine(flutterEngine)
        unregisterAudioAndUsbReceivers()
        closeUsbDevice()
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
        storageChannel?.setMethodCallHandler(null)
        storageChannel = null
        pendingAudioPermissionResult = null
    }

    override fun onDestroy() {
        super.onDestroy()
        // Keep active USB DAC connection alive across Activity recreation/backgrounding
        // when the AudioService FlutterEngine stays running; close only when finishing.
        if (isFinishing) {
            unregisterAudioAndUsbReceivers()
            closeUsbDevice()
            methodChannel?.setMethodCallHandler(null)
            methodChannel = null
            storageChannel?.setMethodCallHandler(null)
            storageChannel = null
            pendingAudioPermissionResult = null
        }
    }

    private fun isUsbOutputType(type: Int): Boolean =
        type == AudioDeviceInfo.TYPE_USB_DEVICE ||
            type == AudioDeviceInfo.TYPE_USB_HEADSET ||
            type == AudioDeviceInfo.TYPE_USB_ACCESSORY

    private fun preferredOutputOrder(): List<Int> {
        val list = mutableListOf(
            AudioDeviceInfo.TYPE_USB_HEADSET,
            AudioDeviceInfo.TYPE_USB_DEVICE,
            AudioDeviceInfo.TYPE_USB_ACCESSORY,
            AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
            AudioDeviceInfo.TYPE_WIRED_HEADSET,
            AudioDeviceInfo.TYPE_LINE_ANALOG,
            AudioDeviceInfo.TYPE_AUX_LINE,
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            list.add(AudioDeviceInfo.TYPE_BLE_HEADSET)
            list.add(AudioDeviceInfo.TYPE_BLE_SPEAKER)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            list.add(AudioDeviceInfo.TYPE_BLE_BROADCAST)
        }
        list.add(AudioDeviceInfo.TYPE_BUILTIN_SPEAKER)
        return list
    }

    private fun pickPreferredDevice(candidates: List<AudioDeviceInfo>): AudioDeviceInfo? {
        if (candidates.isEmpty()) return null
        val order = preferredOutputOrder()
        return order.firstNotNullOfOrNull { wanted ->
            candidates.firstOrNull { it.type == wanted }
        } ?: candidates.firstOrNull()
    }

    private fun resolveActiveOutputDevice(am: AudioManager): AudioDeviceInfo? {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            try {
                val routed = am.getAudioDevicesForAttributes(mediaAudioAttributes)
                val matched = pickPreferredDevice(routed)
                if (matched != null) return matched
            } catch (_: Exception) {}
        }
        val outputs = am.getDevices(AudioManager.GET_DEVICES_OUTPUTS).toList()
        return pickPreferredDevice(outputs)
    }

    private fun getActiveUsbDevice(am: AudioManager): AudioDeviceInfo? {
        val routed = resolveActiveOutputDevice(am)
        if (routed != null && isUsbOutputType(routed.type)) {
            return routed
        }
        return am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
            .firstOrNull { isUsbOutputType(it.type) }
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
        val active = resolveActiveOutputDevice(am) ?: return mapOf("available" to false)

        val isUsb = isUsbOutputType(active.type)

        var supportsBitPerfect = false
        var maxTier = when (typeName(active.type)) {
            "bluetooth", "speaker" -> "resampled"
            "wired" -> "nativeRate"
            else -> "unknown"
        }
        var tierExplanation = ""

        var bitPerfectRates = emptyList<Int>()
        if (isUsb) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                try {
                    val attrs = am.getSupportedMixerAttributes(active)
                    val bpAttrs = attrs.filter { it.mixerBehavior == AudioMixerAttributes.MIXER_BEHAVIOR_BIT_PERFECT }
                    bitPerfectRates = bpAttrs.map { it.format.sampleRate }.filter { it > 0 }.distinct().sorted()
                    val hasBp = bpAttrs.isNotEmpty()
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
            "bitPerfectRates" to bitPerfectRates,
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
    private fun encodingBits(encoding: Int): Int = when (encoding) {
        AudioFormat.ENCODING_PCM_16BIT -> 16
        AudioFormat.ENCODING_PCM_24BIT_PACKED -> 24
        AudioFormat.ENCODING_PCM_32BIT, AudioFormat.ENCODING_PCM_FLOAT -> 32
        else -> 0
    }

    @RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
    private fun scoreMixerCandidate(
        attr: AudioMixerAttributes,
        targetSampleRate: Int,
        targetBitDepth: Int,
    ): Int {
        val fmt = attr.format
        val rate = fmt.sampleRate
        val rateScore = when {
            rate == targetSampleRate -> 1000
            targetSampleRate > 0 && rate > targetSampleRate && rate % targetSampleRate == 0 -> 400
            rate > 0 -> 100
            else -> 0
        }
        val bits = encodingBits(fmt.encoding)
        val depthScore = when {
            bits == targetBitDepth && fmt.encoding != AudioFormat.ENCODING_PCM_FLOAT -> 200
            bits > targetBitDepth -> 170 - (bits - targetBitDepth) // Lossless wider container (e.g. 16 -> 24/32)
            fmt.encoding == AudioFormat.ENCODING_PCM_FLOAT -> 140
            bits > 0 -> 60
            else -> 10
        }
        val channelScore = when (fmt.channelMask) {
            AudioFormat.CHANNEL_OUT_STEREO -> 50
            0 -> 25
            else -> 0
        }
        return rateScore + depthScore + channelScore
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
            val targetBehavior = if (bitPerfect) {
                AudioMixerAttributes.MIXER_BEHAVIOR_BIT_PERFECT
            } else {
                AudioMixerAttributes.MIXER_BEHAVIOR_DEFAULT
            }

            val supported = try {
                am.getSupportedMixerAttributes(device)
            } catch (_: Exception) {
                emptyList()
            }

            val behaviorMatches = supported.filter { it.mixerBehavior == targetBehavior }
            val chosen = if (bitPerfect) {
                // Bit-perfect requires an exact sample rate match; never claim bit-perfect on
                // an integer-multiple upsampled mixer attribute.
                val exactRate = behaviorMatches.filter { it.format.sampleRate == sampleRate }
                exactRate.maxByOrNull { scoreMixerCandidate(it, sampleRate, bitDepth) }
            } else {
                behaviorMatches.maxByOrNull { scoreMixerCandidate(it, sampleRate, bitDepth) }
            }

            if (chosen != null) {
                return am.setPreferredMixerAttributes(mediaAudioAttributes, device, chosen)
            }
            if (!bitPerfect && behaviorMatches.isEmpty()) {
                return am.clearPreferredMixerAttributes(mediaAudioAttributes, device)
            }
            if (supported.isNotEmpty()) {
                // HAL advertised its supported mixer attributes and none matched the requested
                // exact bit-perfect format; reject honestly so BitDrop can fall back cleanly.
                return false
            }

            // Fallback when getSupportedMixerAttributes returned empty on non-standard HALs.
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
            val mixerAttrs = AudioMixerAttributes.Builder(format)
                .setMixerBehavior(targetBehavior)
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

    private fun typeName(type: Int): String = when {
        isUsbOutputType(type) -> "usb"
        type == AudioDeviceInfo.TYPE_WIRED_HEADPHONES ||
            type == AudioDeviceInfo.TYPE_WIRED_HEADSET ||
            type == AudioDeviceInfo.TYPE_LINE_ANALOG ||
            type == AudioDeviceInfo.TYPE_AUX_LINE -> "wired"
        type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP ||
            type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO ||
            (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                (type == AudioDeviceInfo.TYPE_BLE_HEADSET ||
                    type == AudioDeviceInfo.TYPE_BLE_SPEAKER)) ||
            (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                type == AudioDeviceInfo.TYPE_BLE_BROADCAST) -> "bluetooth"
        type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "speaker"
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
        usbPermissionReceiver = null
        pendingUsbPermissionResult?.let { previous ->
            try {
                previous.success(false)
            } catch (_: Exception) {}
        }
        pendingUsbPermissionResult = result

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
                    if (dev != null && dev.deviceId != deviceId) {
                        return
                    }
                    val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                    try {
                        unregisterReceiver(this)
                    } catch (_: Exception) {}
                    usbPermissionReceiver = null
                    val callback = pendingUsbPermissionResult
                    pendingUsbPermissionResult = null
                    runOnUiThread {
                        callback?.success(granted)
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

    private fun requiredAudioPermission(): String =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            Manifest.permission.READ_MEDIA_AUDIO
        } else {
            Manifest.permission.READ_EXTERNAL_STORAGE
        }

    private fun getAudioPermissionStatus(): Map<String, Any> {
        val perm = requiredAudioPermission()
        val granted = ContextCompat.checkSelfPermission(this, perm) ==
            PackageManager.PERMISSION_GRANTED
        val prefs = getSharedPreferences(PREFS_PERMISSIONS, Context.MODE_PRIVATE)
        val askedBefore = prefs.getBoolean(KEY_ASKED_AUDIO_PERM, false)
        val permanentlyDenied = !granted && askedBefore &&
            !ActivityCompat.shouldShowRequestPermissionRationale(this, perm)

        return mapOf(
            "granted" to granted,
            "permanentlyDenied" to permanentlyDenied,
            "permission" to perm,
            "apiLevel" to Build.VERSION.SDK_INT,
        )
    }

    private fun requestAudioPermission(result: MethodChannel.Result) {
        val perm = requiredAudioPermission()
        if (ContextCompat.checkSelfPermission(this, perm) == PackageManager.PERMISSION_GRANTED) {
            result.success(getAudioPermissionStatus())
            return
        }
        pendingAudioPermissionResult?.let { previous ->
            previous.success(getAudioPermissionStatus())
        }
        pendingAudioPermissionResult = result
        getSharedPreferences(PREFS_PERMISSIONS, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_ASKED_AUDIO_PERM, true)
            .apply()
        ActivityCompat.requestPermissions(this, arrayOf(perm), REQ_CODE_AUDIO_PERMISSION)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQ_CODE_AUDIO_PERMISSION) {
            val pending = pendingAudioPermissionResult
            pendingAudioPermissionResult = null
            pending?.success(getAudioPermissionStatus())
        }
    }

    private fun openAppSettings(): Boolean {
        return try {
            val intent = Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.fromParts("package", packageName, null),
            )
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun discoverStorageRoots(): List<Pair<File, Boolean>> {
        val roots = linkedMapOf<String, Pair<File, Boolean>>()
        val sm = getSystemService(Context.STORAGE_SERVICE) as? StorageManager
        if (sm != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            for (vol in sm.storageVolumes) {
                if (vol.state != Environment.MEDIA_MOUNTED &&
                    vol.state != Environment.MEDIA_MOUNTED_READ_ONLY
                ) {
                    continue
                }
                val dir = vol.directory ?: continue
                if (dir.exists() && dir.isDirectory) {
                    roots[dir.absolutePath] = dir to vol.isRemovable
                }
            }
        }

        @Suppress("DEPRECATION")
        val primary = Environment.getExternalStorageDirectory()
        if (primary != null && primary.exists() && primary.isDirectory) {
            roots.putIfAbsent(primary.absolutePath, primary to false)
        }

        // Pre-Android 11 fallback for removable SD card roots via app-specific external dirs.
        getExternalFilesDirs(null).forEachIndexed { idx, appDir ->
            if (appDir == null) return@forEachIndexed
            val path = appDir.absolutePath
            val marker = "/Android/data/"
            val cut = path.indexOf(marker)
            if (cut > 0) {
                val rootDir = File(path.substring(0, cut))
                if (rootDir.exists() && rootDir.isDirectory) {
                    roots.putIfAbsent(rootDir.absolutePath, rootDir to (idx > 0))
                }
            }
        }

        return roots.values.toList()
    }

    private fun discoverMusicDirectories(): List<Map<String, Any>> {
        val roots = discoverStorageRoots()
        val standardNames = listOf("Music", "Download", "Audiobooks", "Audio", "FLAC")
        val excludedTopFolders = setOf(
            "android",
            "alarms",
            "notifications",
            "ringtones",
            "dcim",
            "pictures",
            "movies",
            "recordings",
        )

        data class FoundDir(
            val path: String,
            val label: String,
            val isRemovable: Boolean,
            var audioCount: Int,
        )

        val discovered = linkedMapOf<String, FoundDir>()

        // 1. Always probe standard music directories across primary & removable volumes.
        for ((root, isRemovable) in roots) {
            for (name in standardNames) {
                val candidate = File(root, name)
                if (candidate.exists() && candidate.isDirectory) {
                    val label = if (isRemovable) "SD Card · $name" else name
                    discovered.putIfAbsent(
                        candidate.absolutePath,
                        FoundDir(candidate.absolutePath, label, isRemovable, 0),
                    )
                }
            }
        }

        // 2. When audio permission is granted, also discover any custom top-level folders
        //    containing indexed audio via Android MediaStore (e.g. /FLAC, /Lossless, /HiRes).
        val perm = requiredAudioPermission()
        val hasPerm = ContextCompat.checkSelfPermission(this, perm) ==
            PackageManager.PERMISSION_GRANTED
        if (hasPerm) {
            try {
                @Suppress("DEPRECATION")
                val projection = arrayOf(MediaStore.Audio.Media.DATA)
                val selection = "${MediaStore.Audio.Media.IS_MUSIC} != 0 OR ${MediaStore.Audio.Media.IS_AUDIOBOOK} != 0"
                contentResolver.query(
                    MediaStore.Audio.Media.EXTERNAL_CONTENT_URI,
                    projection,
                    selection,
                    null,
                    null,
                )?.use { cursor ->
                    val dataIdx = cursor.getColumnIndex(MediaStore.Audio.Media.DATA)
                    if (dataIdx >= 0) {
                        while (cursor.moveToNext()) {
                            val filePath = cursor.getString(dataIdx) ?: continue
                            val matchedRoot = roots.firstOrNull { (root, _) ->
                                filePath.startsWith("${root.absolutePath}/")
                            } ?: continue
                            val (rootDir, isRemovable) = matchedRoot
                            val rel = filePath.removePrefix("${rootDir.absolutePath}/")
                            val topSegment = rel.substringBefore('/', missingDelimiterValue = "")
                            if (topSegment.isEmpty() || topSegment.startsWith(".")) continue
                            if (excludedTopFolders.contains(topSegment.lowercase())) continue

                            val folder = File(rootDir, topSegment)
                            if (!folder.exists() || !folder.isDirectory) continue

                            val key = folder.absolutePath
                            val existing = discovered[key]
                            if (existing != null) {
                                existing.audioCount += 1
                            } else {
                                val label = if (isRemovable) "SD Card · $topSegment" else topSegment
                                discovered[key] = FoundDir(key, label, isRemovable, 1)
                            }
                        }
                    }
                }
            } catch (_: Exception) {
                // Ignore MediaStore query failures; standard directories above still apply.
            }
        }

        return discovered.values
            .sortedWith(
                compareByDescending<FoundDir> { it.audioCount > 0 }
                    .thenByDescending { it.audioCount }
                    .thenBy { it.isRemovable }
                    .thenBy { it.label.lowercase() },
            )
            .map { d ->
                mapOf(
                    "path" to d.path,
                    "label" to d.label,
                    "isRemovable" to d.isRemovable,
                    "audioFileCount" to d.audioCount,
                )
            }
    }
}
