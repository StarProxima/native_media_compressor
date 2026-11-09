package io.github.starproxima.native_media_compressor

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

internal class TimeRangeTest {
    @Test
    fun noBoundsKeepEverything() {
        val range = TimeRange.of(null, null)

        assertFalse(range.isTrimmed)
        assertTrue(range.contains(0))
        assertEquals(8_000_000, range.keptDurationUs(8_000_000))
    }

    @Test
    fun outputTimeStartsAtTheRangeStart() {
        val range = TimeRange.of(2000, 5000)

        assertEquals(0, range.toOutput(2_000_000))
        assertTrue(range.contains(2_000_000))
        assertFalse(range.contains(5_000_000))
        assertFalse(range.contains(1_999_999))
        assertEquals(3_000_000, range.keptDurationUs(8_000_000))
    }

    @Test
    fun anEndPastTheSourceKeepsToItsEnd() {
        assertEquals(1_000_000, TimeRange.of(1000, 30_000).keptDurationUs(2_000_000))
    }

    @Test
    fun anUnknownDurationOnlyChecksTheBounds() {
        assertEquals(0, TimeRange.of(1000, null).keptDurationUs(0))
        assertEquals(2_000_000, TimeRange.of(1000, 3000).keptDurationUs(0))
        assertFalse(TimeRange.of(5000, null).keepsNothing(0))
    }

    @Test
    fun emptyRangesKeepNothing() {
        assertTrue(TimeRange.of(3000, 3000).keepsNothing(8_000_000))
        assertTrue(TimeRange.of(4000, 3000).keepsNothing(8_000_000))
        assertTrue(TimeRange.of(9000, null).keepsNothing(8_000_000))
        assertFalse(TimeRange.of(7000, null).keepsNothing(8_000_000))
    }

    @Test
    fun negativeBoundsAreClampedToTheStart() {
        val range = TimeRange.of(-500, -100)

        assertEquals(0, range.startUs)
        assertTrue(range.keepsNothing(8_000_000))
    }

    @Test
    fun pcmFramesAreCutAtBothBounds() {
        val range = TimeRange.of(1000, 2000)

        // 1024 frames at 48 kHz starting 10 ms before the start: 480 are cut.
        assertEquals(480 until 1024, range.pcmFrames(990_000, 1024, 48_000))
        // A buffer over the end keeps the frames before it.
        assertEquals(0 until 480, range.pcmFrames(1_990_000, 1024, 48_000))
        assertTrue(range.pcmFrames(2_000_000, 1024, 48_000).isEmpty())
        assertTrue(range.pcmFrames(900_000, 1024, 48_000).isEmpty())
    }

    @Test
    fun anOpenRangeKeepsPcmAfterTheStart() {
        val range = TimeRange.of(null, null)

        assertEquals(0 until 1024, range.pcmFrames(0, 1024, 44_100))
        // Priming samples before zero are dropped.
        assertEquals(441 until 1024, range.pcmFrames(-10_000, 1024, 44_100))
    }

    @Test
    fun frameRateComesFromTheFrameCount() {
        assertEquals(30.0, FrameRate.average(60, 2_000_000))
        assertEquals(29.97, FrameRate.average(2997, 100_000_000)!!, 1e-9)
        assertNull(FrameRate.average(null, 2_000_000))
        assertNull(FrameRate.average(60, 0))
    }

    @Test
    fun aTimescaleReportedAsTheRateIsIgnored() {
        assertNull(FrameRate.plausible(19_200.0))
        assertEquals(60.0, FrameRate.plausible(60.0))
        assertNull(FrameRate.plausible(0.0))
    }
}
