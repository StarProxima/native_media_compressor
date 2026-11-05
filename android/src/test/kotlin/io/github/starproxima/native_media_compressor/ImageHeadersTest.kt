package io.github.starproxima.native_media_compressor

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import kotlin.test.Test
import kotlin.test.assertEquals

internal class ImageHeadersTest {
    @Test
    fun detectsHeicByBrand() {
        val header = byteArrayOf(0, 0, 0, 0x18) + "ftypmif1".toByteArray() + byteArrayOf(0, 0, 0, 0) +
            "mif1heic".toByteArray()
        assertEquals("image/heic", ImageHeaders.mimeType(header))
    }

    @Test
    fun detectsAvifByMajorBrand() {
        val header = byteArrayOf(0, 0, 0, 0x14) + "ftypavif".toByteArray() + byteArrayOf(0, 0, 0, 0) +
            "mif1".toByteArray()
        assertEquals("image/avif", ImageHeaders.mimeType(header))
    }

    @Test
    fun countsGifImageDescriptors() {
        val gif = ByteArrayOutputStream().apply {
            write("GIF89a".toByteArray())
            write(byteArrayOf(1, 0, 1, 0, 0x80.toByte(), 0, 0))
            write(ByteArray(6))
            repeat(3) {
                write(byteArrayOf(0x21, 0xF9.toByte(), 4, 0, 10, 0, 0, 0))
                write(byteArrayOf(0x2C, 0, 0, 0, 0, 1, 0, 1, 0, 0, 2, 2, 0x4C, 0x01, 0))
            }
            write(0x3B)
        }.toByteArray()
        assertEquals(3, ImageHeaders.frameCount("image/gif", ByteArrayInputStream(gif)))
    }

    @Test
    fun countsWebpAnimationFrames() {
        val webp = ByteArrayOutputStream().apply {
            write("RIFF".toByteArray())
            write(ByteArray(4))
            write("WEBP".toByteArray())
            write(chunk("VP8X", 10))
            write(chunk("ANIM", 6))
            repeat(2) { write(chunk("ANMF", 3)) }
        }.toByteArray()
        assertEquals(2, ImageHeaders.frameCount("image/webp", ByteArrayInputStream(webp)))
    }

    @Test
    fun readsApngFrameCount() {
        val png = ByteArrayOutputStream().apply {
            write(byteArrayOf(0x89.toByte(), 'P'.code.toByte(), 'N'.code.toByte(), 'G'.code.toByte(), 13, 10, 26, 10))
            write(byteArrayOf(0, 0, 0, 13) + "IHDR".toByteArray() + ByteArray(13 + 4))
            write(byteArrayOf(0, 0, 0, 8) + "acTL".toByteArray() + byteArrayOf(0, 0, 0, 5, 0, 0, 0, 0))
        }.toByteArray()
        assertEquals(5, ImageHeaders.frameCount("image/png", ByteArrayInputStream(png)))
    }

    @Test
    fun truncatedFileCountsAtLeastOneFrame() {
        assertEquals(1, ImageHeaders.frameCount("image/gif", ByteArrayInputStream("GIF8".toByteArray())))
    }

    private fun chunk(fourCc: String, size: Int): ByteArray =
        fourCc.toByteArray() + byteArrayOf(size.toByte(), 0, 0, 0) + ByteArray(size + (size and 1))
}
