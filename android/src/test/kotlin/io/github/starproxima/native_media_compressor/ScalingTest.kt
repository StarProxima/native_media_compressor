package io.github.starproxima.native_media_compressor

import kotlin.test.Test
import kotlin.test.assertEquals

internal class ScalingTest {
    @Test
    fun imageFitsTheTighterBound() {
        assertEquals(Size(300, 400), Scaling.imageSize(Size(1200, 1600), maxShortSide = 300, maxLongSide = 1000))
    }

    @Test
    fun imageIsNeverScaledUp() {
        assertEquals(Size(1200, 800), Scaling.imageSize(Size(1200, 800), maxShortSide = null, maxLongSide = 4000))
    }

    @Test
    fun videoKeepsTheAspectWithEvenSides() {
        assertEquals(Size(640, 360), video(Size(1920, 1080), maxShortSide = 360, alignment = 2))
        assertEquals(Size(1920, 1080), video(Size(1920, 1080), maxShortSide = 1080, alignment = 2))
        assertEquals(Size(720, 1564), video(Size(1206, 2622), maxShortSide = 720, alignment = 2))
    }

    @Test
    fun videoFallsBackToMultiplesOf16() {
        assertEquals(Size(640, 352), video(Size(1920, 1080), maxShortSide = 360, alignment = 16))
    }

    @Test
    fun videoStaysWithinASmallBound() {
        assertEquals(Size(14, 8), video(Size(1920, 1080), maxShortSide = 8, alignment = 2))
    }

    @Test
    fun quarterTurnsAddToTheSourceRotation() {
        assertEquals(90, Rotation.add(0, 1))
        assertEquals(0, Rotation.add(90, 3))
        assertEquals(180, Rotation.add(270, 3))
        assertEquals(270, Rotation.add(-90, 0))
    }

    @Test
    fun anOddTurnSwapsTheDisplayedSides() {
        assertEquals(Size(360, 640), Size(640, 360).rotated(Rotation.add(0, 1)))
        assertEquals(Size(640, 360), Size(640, 360).rotated(Rotation.add(90, 1)))
    }

    private fun video(size: Size, maxShortSide: Long, alignment: Int) =
        Scaling.videoSize(size, maxShortSide, maxLongSide = null, widthAlignment = alignment, heightAlignment = alignment)
}
