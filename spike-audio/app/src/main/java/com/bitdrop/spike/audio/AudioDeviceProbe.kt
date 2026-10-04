package com.bitdrop.spike.audio

import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.os.Build

data class DeviceCapabilities(
    val productName: String,
    val id: Int,
    val type: Int,
    val isUsb: Boolean,
    val sampleRates: List<Int>,
    val channelCounts: List<Int>,
    val channelMasks: List<Int>,
    val encodings: List<String>
)

object AudioDeviceProbe {
    fun probeDevices(audioManager: AudioManager): Pair<List<DeviceCapabilities>, List<DeviceCapabilities>> {
        val allDevices = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
        val usbDevices = mutableListOf<DeviceCapabilities>()
        val otherDevices = mutableListOf<DeviceCapabilities>()

        for (device in allDevices) {
            val isUsb = device.type == AudioDeviceInfo.TYPE_USB_DEVICE ||
                    device.type == AudioDeviceInfo.TYPE_USB_HEADSET ||
                    device.type == AudioDeviceInfo.TYPE_USB_ACCESSORY

            val productName = device.productName?.toString() ?: "Unknown Device"
            val encodings = device.encodings.map { mapEncodingToString(it) }

            val caps = DeviceCapabilities(
                productName = productName,
                id = device.id,
                type = device.type,
                isUsb = isUsb,
                sampleRates = device.sampleRates.toList(),
                channelCounts = device.channelCounts.toList(),
                channelMasks = device.channelMasks.toList(),
                encodings = encodings
            )

            if (isUsb) {
                usbDevices.add(caps)
            } else {
                otherDevices.add(caps)
            }
        }
        return Pair(usbDevices, otherDevices)
    }

    private fun mapEncodingToString(encoding: Int): String {
        return when (encoding) {
            AudioFormat.ENCODING_PCM_8BIT -> "PCM_8BIT"
            AudioFormat.ENCODING_PCM_16BIT -> "PCM_16BIT"
            AudioFormat.ENCODING_PCM_24BIT_PACKED -> "PCM_24BIT_PACKED"
            AudioFormat.ENCODING_PCM_32BIT -> "PCM_32BIT"
            AudioFormat.ENCODING_PCM_FLOAT -> "PCM_FLOAT"
            AudioFormat.ENCODING_INVALID -> "INVALID"
            AudioFormat.ENCODING_DEFAULT -> "DEFAULT"
            else -> "UNKNOWN_ENCODING_$encoding"
        }
    }
}
