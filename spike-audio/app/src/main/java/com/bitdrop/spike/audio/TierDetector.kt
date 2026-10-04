package com.bitdrop.spike.audio

import android.os.Build

data class TierResult(
    val tier: String,
    val explanation: String
)

object TierDetector {
    fun detectTier(usbDevices: List<DeviceCapabilities>, mixerAttributes: List<MixerAttributeInfo>?): TierResult {
        if (usbDevices.isEmpty()) {
            return TierResult("C", "No USB DAC detected.")
        }

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            return TierResult("C", "Android version < 14 (API 34). Bit-perfect API not supported.")
        }

        if (mixerAttributes.isNullOrEmpty()) {
            return TierResult("C", "API 34+ detected, but no Mixer Attributes found for USB DAC.")
        }

        val hasBitPerfect = mixerAttributes.any { it.isBitPerfect }
        return if (hasBitPerfect) {
            TierResult("A", "API 34+ and BIT_PERFECT mixer attributes available.")
        } else {
            TierResult("B", "API 34+ and mixer attributes present, but NO bit-perfect behavior available.")
        }
    }
}
