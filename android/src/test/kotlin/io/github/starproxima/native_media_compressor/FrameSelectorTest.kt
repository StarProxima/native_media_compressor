package io.github.starproxima.native_media_compressor

import kotlin.test.Test
import kotlin.test.assertEquals

internal class FrameSelectorTest {
    private fun keptOfOneSecond(sourceRate: Int, cap: Int?): Int {
        val selector = FrameSelector(cap)
        return (0 until sourceRate).count { selector.accept(it * 1_000_000L / sourceRate) }
    }

    @Test
    fun aSourceSlightlyAboveTheCapKeepsTheCapRate() {
        assertEquals(30, keptOfOneSecond(sourceRate = 32, cap = 30))
    }

    @Test
    fun aDoubleRateSourceKeepsEveryOtherFrame() {
        assertEquals(30, keptOfOneSecond(sourceRate = 60, cap = 30))
    }

    @Test
    fun aSourceBelowTheCapKeepsEveryFrame() {
        assertEquals(24, keptOfOneSecond(sourceRate = 24, cap = 30))
    }

    @Test
    fun noCapKeepsEveryFrame() {
        assertEquals(120, keptOfOneSecond(sourceRate = 120, cap = null))
    }
}
