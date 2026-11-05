package io.github.starproxima.native_media_compressor

import kotlin.test.Test
import kotlin.test.assertEquals

internal class SampleLevelsTest {
    @Test
    fun p010LimitedRangeUsesTenBitCodesShiftedBySix() {
        val levels = SampleLevels.of(sampleBytes = 2, isFullRange = false)
        // Black 64 << 6, white 940 << 6, chroma center 512 << 6, chroma range 896 << 6.
        assertEquals(4096f / 65535f, levels[0], 1e-7f)
        assertEquals(60160f / 65535f, levels[0] + levels[1], 1e-6f)
        assertEquals(32768f / 65535f, levels[2], 1e-7f)
        assertEquals(57344f / 65535f, levels[3], 1e-7f)
    }

    @Test
    fun eightBitLimitedRangeUsesStudioLevels() {
        val levels = SampleLevels.of(sampleBytes = 1, isFullRange = false)
        assertEquals(16f / 255f, levels[0], 1e-7f)
        assertEquals(219f / 255f, levels[1], 1e-7f)
        assertEquals(128f / 255f, levels[2], 1e-7f)
        assertEquals(224f / 255f, levels[3], 1e-7f)
    }
}
