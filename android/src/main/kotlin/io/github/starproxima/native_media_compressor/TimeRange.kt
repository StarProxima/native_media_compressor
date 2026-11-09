package io.github.starproxima.native_media_compressor

import kotlin.math.ceil

/** The part of the source timeline a compression keeps, in microseconds; output time 0 is [startUs]. */
internal class TimeRange(val startUs: Long, val endUs: Long) {
    val isTrimmed: Boolean get() = startUs > 0 || endUs != Long.MAX_VALUE

    fun contains(timeUs: Long): Boolean = timeUs in startUs until endUs

    fun toOutput(timeUs: Long): Long = timeUs - startUs

    /** Whether nothing of a source lasting [durationUs] is kept; an unknown duration (0) only checks the bounds. */
    fun keepsNothing(durationUs: Long): Boolean = endUs <= startUs || (durationUs > 0 && startUs >= durationUs)

    /** Length of the kept part of a source lasting [durationUs], 0 when neither is known. */
    fun keptDurationUs(durationUs: Long): Long {
        val end = if (durationUs > 0) minOf(endUs, durationUs) else endUs
        return if (end == Long.MAX_VALUE) 0 else (end - startUs).coerceAtLeast(0)
    }

    /**
     * Index range of the PCM frames to keep from a buffer of [frameCount] frames
     * at [sampleRate] that starts at [bufferUs]; empty when none is kept.
     */
    fun pcmFrames(bufferUs: Long, frameCount: Int, sampleRate: Int): IntRange {
        fun frameAt(timeUs: Long): Int {
            if (timeUs <= bufferUs) return 0
            if (timeUs == Long.MAX_VALUE) return frameCount
            return ceil((timeUs - bufferUs) * sampleRate / 1_000_000.0).toLong().coerceAtMost(frameCount.toLong()).toInt()
        }
        val first = frameAt(startUs)
        val end = frameAt(endUs)
        return first until maxOf(first, end)
    }

    companion object {
        val ALL = TimeRange(0, Long.MAX_VALUE)

        fun of(startMs: Long?, endMs: Long?): TimeRange = TimeRange(
            startUs = (startMs ?: 0).coerceAtLeast(0) * 1000,
            endUs = endMs?.let { it.coerceAtLeast(0) * 1000 } ?: Long.MAX_VALUE,
        )
    }
}

internal object FrameRate {
    // Variable frame rate recordings can report their timescale, such as 19200, as the rate.
    private const val MAX_PLAUSIBLE = 480.0

    /** Average rate of [frameCount] frames over [durationUs]; null when either is unknown. */
    fun average(frameCount: Long?, durationUs: Long?): Double? {
        if (frameCount == null || frameCount <= 0 || durationUs == null || durationUs <= 0) return null
        return plausible(frameCount * 1_000_000.0 / durationUs)
    }

    fun plausible(rate: Double?): Double? = rate?.takeIf { it > 0 && it <= MAX_PLAUSIBLE }
}
