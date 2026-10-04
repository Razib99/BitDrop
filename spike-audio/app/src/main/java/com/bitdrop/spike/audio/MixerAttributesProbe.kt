package com.bitdrop.spike.audio

import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.AudioMixerAttributes
import android.os.Build
import androidx.annotation.RequiresApi

data class MixerAttributeInfo(
    val encoding: Int,
    val sampleRate: Int,
    val channelMask: Int,
    val behavior: Int,
    val isBitPerfect: Boolean
)

object MixerAttributesProbe {

    @RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
    fun getMixerAttributes(audioManager: AudioManager, device: AudioDeviceInfo): List<MixerAttributeInfo> {
        val attributes = audioManager.getSupportedMixerAttributes(device)
        return attributes.map { attr ->
            MixerAttributeInfo(
                encoding = attr.format.encoding,
                sampleRate = attr.format.sampleRate,
                channelMask = attr.format.channelMask,
                behavior = attr.mixerBehavior,
                isBitPerfect = attr.mixerBehavior == AudioMixerAttributes.MIXER_BEHAVIOR_BIT_PERFECT
            )
        }
    }
}
