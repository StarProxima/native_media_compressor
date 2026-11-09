package io.github.starproxima.native_media_compressor

import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

internal data class Size(val width: Int, val height: Int) {
    fun transposed() = Size(height, width)

    /** The size shown after turning by [degrees], a multiple of 90. */
    fun rotated(degrees: Int) = if (degrees % 180 != 0) transposed() else this
}

internal object Rotation {
    /** [degrees] turned clockwise by [quarterTurns], within 0 until 360. */
    fun add(degrees: Int, quarterTurns: Long): Int = (((degrees + quarterTurns % 4 * 90) % 360 + 360) % 360).toInt()

    fun normalize(degrees: Int): Int = (degrees % 360 + 360) % 360
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

    /** Scaled size with each side rounded down to a multiple of what the encoder requires. */
    fun videoSize(size: Size, maxShortSide: Long?, maxLongSide: Long?, widthAlignment: Int, heightAlignment: Int): Size {
        val scale = factor(size, maxShortSide, maxLongSide)
        return Size(alignDown(size.width * scale, widthAlignment), alignDown(size.height * scale, heightAlignment))
    }

    // The epsilon keeps 639.9999 from a 1/3 factor at 640. 4:2:0 frames need even sides.
    private fun alignDown(value: Double, alignment: Int): Int {
        val step = max(2, alignment)
        return max(step, ((value + 1e-6).toInt() / step) * step)
    }
}
