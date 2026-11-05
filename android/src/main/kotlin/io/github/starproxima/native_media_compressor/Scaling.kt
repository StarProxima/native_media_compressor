package io.github.starproxima.native_media_compressor

import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

internal data class Size(val width: Int, val height: Int) {
    fun transposed() = Size(height, width)
}

internal object Scaling {
    /** Factor that fits [size] into both bounds without ever scaling up; absent bounds are ignored. */
    fun factor(size: Size, maxShortSide: Long?, maxLongSide: Long?): Double {
        var scale = 1.0
        if (maxShortSide != null && maxShortSide > 0) {
            scale = min(scale, maxShortSide.toDouble() / min(size.width, size.height))
        }
        if (maxLongSide != null && maxLongSide > 0) {
            scale = min(scale, maxLongSide.toDouble() / max(size.width, size.height))
        }
        return scale
    }

    fun imageSize(size: Size, maxShortSide: Long?, maxLongSide: Long?): Size {
        val scale = factor(size, maxShortSide, maxLongSide)
        if (scale >= 1.0) return size
        return Size(
            max(1, (size.width * scale).roundToInt()),
            max(1, (size.height * scale).roundToInt()),
        )
    }

    // Hardware H.264 encoders reliably accept only sizes that are multiples of 16.
    fun videoSize(size: Size, maxShortSide: Long?, maxLongSide: Long?): Size {
        val scale = factor(size, maxShortSide, maxLongSide)
        return Size(alignDownTo16(size.width * scale), alignDownTo16(size.height * scale))
    }

    // The epsilon keeps 639.9999 from a 1/3 factor at 640.
    private fun alignDownTo16(value: Double): Int = max(16, ((value + 1e-6).toInt() / 16) * 16)
}
