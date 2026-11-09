package io.github.starproxima.native_media_compressor

import android.media.AudioFormat
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertSame

internal class Pcm16Test {
    private fun samples(buffer: ByteBuffer): List<Int> {
        val shorts = buffer.order(ByteOrder.nativeOrder()).asShortBuffer()
        return List(shorts.remaining()) { shorts.get(it).toInt() }
    }

    private fun bytes(vararg values: Int): ByteBuffer =
        ByteBuffer.allocate(values.size).apply { values.forEach { put(it.toByte()) }; flip() }

    @Test
    fun sixteenBitSamplesStayAsTheyAre() {
        val source = ByteBuffer.allocate(6).order(ByteOrder.nativeOrder())
        source.putShort(1).putShort(-2).putShort(Short.MAX_VALUE).flip()

        assertEquals(listOf(1, -2, Short.MAX_VALUE.toInt()), samples(Pcm16.convert(source, AudioFormat.ENCODING_PCM_16BIT, ByteBuffer.allocate(0))))
    }

    @Test
    fun floatSamplesAreScaledAndClipped() {
        val source = ByteBuffer.allocate(16).order(ByteOrder.nativeOrder())
        source.putFloat(0f).putFloat(0.5f).putFloat(-1f).putFloat(2f).flip()

        assertEquals(listOf(0, 16384, -32767, 32767), samples(Pcm16.convert(source, AudioFormat.ENCODING_PCM_FLOAT, ByteBuffer.allocate(0))))
    }

    @Test
    fun eightBitSamplesAreCentred() {
        assertEquals(listOf(-32768, 0, 32512), samples(Pcm16.convert(bytes(0, 128, 255), AudioFormat.ENCODING_PCM_8BIT, ByteBuffer.allocate(0))))
    }

    @Test
    fun wideSamplesKeepTheirTopBits() {
        // 24-bit packed little-endian: 0x123456 and -1.
        val packed = bytes(0x56, 0x34, 0x12, 0xFF, 0xFF, 0xFF)
        assertEquals(listOf(0x1234, -1), samples(Pcm16.convert(packed, 21, ByteBuffer.allocate(0))))

        val source = ByteBuffer.allocate(8).order(ByteOrder.nativeOrder())
        source.putInt(0x12345678).putInt(Int.MIN_VALUE).flip()
        assertEquals(listOf(0x1234, -32768), samples(Pcm16.convert(source, 22, ByteBuffer.allocate(0))))
    }

    @Test
    fun aLargeEnoughTargetIsReused() {
        val target = ByteBuffer.allocateDirect(64)
        val source = ByteBuffer.allocate(4).order(ByteOrder.nativeOrder())
        source.putShort(7).putShort(8).flip()

        assertSame(target, Pcm16.convert(source, AudioFormat.ENCODING_PCM_16BIT, target))
    }

    @Test
    fun compressedEncodingsAreNotConverted() {
        assertNull(Pcm16.bytesPerSample(AudioFormat.ENCODING_AC3))
    }
}
