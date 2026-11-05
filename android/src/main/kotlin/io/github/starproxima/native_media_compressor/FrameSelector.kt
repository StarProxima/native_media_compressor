package io.github.starproxima.native_media_compressor

import kotlin.math.roundToLong

/**
 * Picks the frames to keep under a frame rate cap: one per slot of a fixed grid at
 * the cap, with source timestamps kept. Measuring from the last kept frame instead
 * would keep only every other frame of a source slightly faster than the cap.
 */
internal class FrameSelector(private val maxFrameRate: Int?) {
    private var lastSlot = Long.MIN_VALUE

    fun accept(timeUs: Long): Boolean {
        val rate = maxFrameRate ?: return true
        val slot = (timeUs * rate / 1_000_000.0).roundToLong()
        if (slot <= lastSlot) return false
        lastSlot = slot
        return true
    }
}
