package io.github.starproxima.native_media_compressor

import android.media.AudioFormat
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.roundToInt

/** Converts decoded PCM to the 16-bit samples AAC encoders take. */
internal object Pcm16 {
    // AudioFormat.ENCODING_PCM_24BIT_PACKED and ENCODING_PCM_32BIT, named only from API 31.
    private const val ENCODING_PCM_24BIT_PACKED = 21
    private const val ENCODING_PCM_32BIT = 22

    /** Bytes per sample of [encoding], null for encodings this cannot convert. */
    fun bytesPerSample(encoding: Int): Int? = when (encoding) {
        AudioFormat.ENCODING_PCM_8BIT -> 1
        AudioFormat.ENCODING_PCM_16BIT -> 2
        ENCODING_PCM_24BIT_PACKED -> 3
        ENCODING_PCM_32BIT, AudioFormat.ENCODING_PCM_FLOAT -> 4
        else -> null
    }

    /**
     * Writes the samples between [source]'s position and limit to [target] as
     * 16-bit PCM and returns [target], or a larger buffer when it is too small,
     * flipped for reading.
     */
    fun convert(source: ByteBuffer, encoding: Int, target: ByteBuffer): ByteBuffer {
        val input = source.slice().order(ByteOrder.nativeOrder())
        val bytes = requireNotNull(bytesPerSample(encoding)) { "PCM encoding $encoding" }
        val samples = input.remaining() / bytes
        val output = (if (target.capacity() >= samples * 2) target else ByteBuffer.allocateDirect(samples * 2))
            .order(ByteOrder.nativeOrder())
        output.clear()
        repeat(samples) {
            val sample = when (encoding) {
                AudioFormat.ENCODING_PCM_8BIT -> ((input.get().toInt() and 0xFF) - 128) shl 8
                AudioFormat.ENCODING_PCM_16BIT -> input.getShort().toInt()
                // Every Android ABI is little-endian: the low byte is dropped.
                ENCODING_PCM_24BIT_PACKED -> {
                    input.get()
                    val middle = input.get().toInt() and 0xFF
                    val high = input.get().toInt()
                    (high shl 8) or middle
                }
                ENCODING_PCM_32BIT -> input.getInt() shr 16
                else -> (input.getFloat().coerceIn(-1f, 1f) * Short.MAX_VALUE).roundToInt()
            }
            output.putShort(sample.toShort())
        }
        output.flip()
        return output
    }
}
