package io.github.starproxima.native_media_compressor

/**
 * Luma black and range, chroma center and range of decoded YUV samples, normalized
 * the way the tone-mapping shader reads them: an 8-bit sample over 255, a 10-bit
 * sample in the top bits of a 16-bit word (P010) over 65535.
 */
internal object SampleLevels {
    fun of(sampleBytes: Int, isFullRange: Boolean): FloatArray {
        val (scale, max) = if (sampleBytes == 2) 64f to 65535f else 1f to 255f
        val codes = when {
            sampleBytes == 2 && isFullRange -> floatArrayOf(0f, 1023f, 512f, 1023f)
            sampleBytes == 2 -> floatArrayOf(64f, 876f, 512f, 896f)
            isFullRange -> floatArrayOf(0f, 255f, 128f, 255f)
            else -> floatArrayOf(16f, 219f, 128f, 224f)
        }
        return FloatArray(4) { codes[it] * scale / max }
    }
}
