package com.bitdrop.spike.audio

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Build
import android.os.Bundle
import android.widget.Button
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity

class AudioProbeActivity : AppCompatActivity() {

    private lateinit var tvResults: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_probe)

        tvResults = findViewById(R.id.tv_results)

        findViewById<Button>(R.id.btn_probe).setOnClickListener {
            runProbes()
        }

        findViewById<Button>(R.id.btn_copy).setOnClickListener {
            val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            val clip = ClipData.newPlainText("Audio Probe Report", tvResults.text)
            clipboard.setPrimaryClip(clip)
            Toast.makeText(this, "Copied to clipboard", Toast.LENGTH_SHORT).show()
        }

        findViewById<Button>(R.id.btn_share).setOnClickListener {
            val sendIntent: Intent = Intent().apply {
                action = Intent.ACTION_SEND
                putExtra(Intent.EXTRA_TEXT, tvResults.text.toString())
                type = "text/plain"
            }
            val shareIntent = Intent.createChooser(sendIntent, null)
            startActivity(shareIntent)
        }

        runProbes()
    }

    private fun runProbes() {
        val sb = StringBuilder()
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager

        sb.append("=== Section 1: Device Info ===\n")
        sb.append("Android Version: ${Build.VERSION.RELEASE}\n")
        sb.append("API Level: ${Build.VERSION.SDK_INT}\n")
        sb.append("Device Model: ${Build.MODEL}\n\n")

        val (usbCaps, otherCaps) = try {
            AudioDeviceProbe.probeDevices(audioManager)
        } catch (e: Exception) {
            sb.append("Error probing devices: ${e.message}\n")
            Pair(emptyList<DeviceCapabilities>(), emptyList<DeviceCapabilities>())
        }

        sb.append("=== Section 2: Connected Audio Devices (Non-USB) ===\n")
        if (otherCaps.isEmpty()) sb.append("None\n")
        otherCaps.forEach { caps ->
            sb.append("- ${caps.productName} (Type: ${caps.type}, ID: ${caps.id})\n")
        }
        sb.append("\n")

        sb.append("=== Section 3: USB DAC Details ===\n")
        if (usbCaps.isEmpty()) sb.append("None detected\n")
        usbCaps.forEach { caps ->
            sb.append("Name: ${caps.productName}\n")
            sb.append("Type: ${caps.type}, ID: ${caps.id}\n")
            sb.append("Sample Rates: ${caps.sampleRates.joinToString()}\n")
            sb.append("Channel Counts: ${caps.channelCounts.joinToString()}\n")
            sb.append("Channel Masks: ${caps.channelMasks.joinToString()}\n")
            sb.append("Encodings: ${caps.encodings.joinToString()}\n")
            sb.append("\n")
        }

        sb.append("=== Section 4: Mixer Attributes ===\n")
        var mixerAttributes: List<MixerAttributeInfo>? = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val allDevices = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
            val usbDevices = allDevices.filter {
                it.type == AudioDeviceInfo.TYPE_USB_DEVICE ||
                it.type == AudioDeviceInfo.TYPE_USB_HEADSET ||
                it.type == AudioDeviceInfo.TYPE_USB_ACCESSORY
            }
            if (usbDevices.isNotEmpty()) {
                val dev = usbDevices.first()
                try {
                    mixerAttributes = MixerAttributesProbe.getMixerAttributes(audioManager, dev)
                    if (mixerAttributes.isEmpty()) {
                        sb.append("No mixer attributes found for ${dev.productName}\n")
                    } else {
                        mixerAttributes.forEach { attr ->
                            sb.append("- BitPerfect: ${attr.isBitPerfect}, Encoding: ${attr.encoding}, SR: ${attr.sampleRate}, Mask: ${attr.channelMask}\n")
                        }
                    }
                } catch (e: Exception) {
                    sb.append("Error fetching mixer attributes: ${e.message}\n")
                }
            } else {
                sb.append("No USB device to query mixer attributes.\n")
            }
        } else {
            sb.append("Not available on API ${Build.VERSION.SDK_INT} (Requires 34+)\n")
        }
        sb.append("\n")

        sb.append("=== Section 5: Tier Assessment ===\n")
        val tierResult = TierDetector.detectTier(usbCaps, mixerAttributes)
        sb.append("Tier: ${tierResult.tier}\n")
        sb.append("Explanation: ${tierResult.explanation}\n\n")

        sb.append("=== Section 6: AudioTrack Test ===\n")
        val testConfigs = listOf(
            Pair(AudioFormat.ENCODING_PCM_16BIT, 44100),
            Pair(AudioFormat.ENCODING_PCM_16BIT, 48000),
            Pair(AudioFormat.ENCODING_PCM_24BIT_PACKED, 44100),
            Pair(AudioFormat.ENCODING_PCM_24BIT_PACKED, 96000),
            Pair(AudioFormat.ENCODING_PCM_24BIT_PACKED, 192000),
            Pair(AudioFormat.ENCODING_PCM_32BIT, 96000),
            Pair(AudioFormat.ENCODING_PCM_FLOAT, 96000)
        )

        val usbDev = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).firstOrNull {
            it.type == AudioDeviceInfo.TYPE_USB_DEVICE ||
            it.type == AudioDeviceInfo.TYPE_USB_HEADSET ||
            it.type == AudioDeviceInfo.TYPE_USB_ACCESSORY
        }

        testConfigs.forEach { (encoding, sampleRate) -\u003e
            val encName = encodingName(encoding)
            try {
                val format = AudioFormat.Builder()
                    .setEncoding(encoding)
                    .setSampleRate(sampleRate)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                    .build()

                val track = AudioTrack.Builder()
                    .setAudioFormat(format)
                    .setTransferMode(AudioTrack.MODE_STREAM)
                    .build()

                if (usbDev != null) {
                    track.preferredDevice = usbDev
                }

                val state = if (track.state == AudioTrack.STATE_INITIALIZED) "INITIALIZED" else "UNINITIALIZED"
                sb.append("$encName @ ${sampleRate}Hz: $state\n")

                if (track.state == AudioTrack.STATE_INITIALIZED) {
                    val actualFormat = track.format
                    sb.append("   -> Actual: ${encodingName(actualFormat.encoding)} @ ${actualFormat.sampleRate}Hz\n")
                }

                track.release()
            } catch (e: Exception) {
                sb.append("$encName @ ${sampleRate}Hz: FAILED (${e.message})\n")
            }
        }

        tvResults.text = sb.toString()
    }

    private fun encodingName(encoding: Int): String = when (encoding) {
        AudioFormat.ENCODING_PCM_8BIT -> "PCM_8BIT"
        AudioFormat.ENCODING_PCM_16BIT -> "PCM_16BIT"
        AudioFormat.ENCODING_PCM_24BIT_PACKED -> "PCM_24BIT"
        AudioFormat.ENCODING_PCM_32BIT -> "PCM_32BIT"
        AudioFormat.ENCODING_PCM_FLOAT -> "PCM_FLOAT"
        AudioFormat.ENCODING_DEFAULT -> "DEFAULT"
        else -> "UNKNOWN($encoding)"
    }
}
