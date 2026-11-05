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
    fun videoSidesAreMultiplesOf16WithinTheBound() {
        assertEquals(Size(640, 352), Scaling.videoSize(Size(1920, 1080), maxShortSide = 360, maxLongSide = null))
    }
}
