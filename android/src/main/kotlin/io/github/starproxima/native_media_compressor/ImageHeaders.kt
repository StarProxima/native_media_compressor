package io.github.starproxima.native_media_compressor

import java.io.EOFException
import java.io.InputStream

/**
 * Container-level parsing for what Android has no API for: the exact HEIC/HEIF/AVIF
 * MIME type and the frame count of animated GIF, WebP and PNG.
 */
internal object ImageHeaders {
    private val HEIC_BRANDS = setOf("heic", "heix", "heim", "heis", "hevc", "hevx")
    private val AVIF_BRANDS = setOf("avif", "avis")
    private const val IMAGE_DESCRIPTOR = 0x2C
    private const val EXTENSION = 0x21

    fun mimeType(header: ByteArray): String? = when {
        header.startsWith(0xFF, 0xD8, 0xFF) -> "image/jpeg"
        header.startsWith(0x89, 'P'.code, 'N'.code, 'G'.code) -> "image/png"
        header.ascii(0, 4) == "GIF8" -> "image/gif"
        header.ascii(0, 4) == "RIFF" && header.ascii(8, 4) == "WEBP" -> "image/webp"
        header.ascii(0, 2) == "BM" -> "image/bmp"
        header.startsWith('I'.code, 'I'.code, 0x2A, 0x00) -> "image/tiff"
        header.startsWith('M'.code, 'M'.code, 0x00, 0x2A) -> "image/tiff"
        header.ascii(4, 4) == "ftyp" -> isoMimeType(header)
        else -> null
    }

    private fun isoMimeType(header: ByteArray): String? {
        val boxSize = header.uint32BigEndian(0).coerceIn(8, header.size.toLong()).toInt()
        val major = header.ascii(8, 4)
        val compatible = (16 until boxSize - 3 step 4).mapNotNull { header.ascii(it, 4) }
        return when {
            major in AVIF_BRANDS -> "image/avif"
            major in HEIC_BRANDS -> "image/heic"
            compatible.any { it in HEIC_BRANDS } -> "image/heic"
            compatible.any { it in AVIF_BRANDS } -> "image/avif"
            major == "mif1" || major == "msf1" || "mif1" in compatible || "msf1" in compatible -> "image/heif"
            else -> null
        }
    }

    /** Frame count for formats that can be animated, 1 for everything else. */
    fun frameCount(mimeType: String?, stream: InputStream): Int {
        val counter = FrameCounter()
        try {
            when (mimeType) {
                "image/gif" -> countGifFrames(stream, counter)
                "image/webp" -> countWebpFrames(stream, counter)
                "image/png" -> countPngFrames(stream, counter)
            }
        } catch (_: EOFException) {
            // A truncated file still reports the frames read so far.
        }
        return counter.frames.coerceAtLeast(1)
    }

    private class FrameCounter {
        var frames = 0
    }

    private fun countGifFrames(stream: InputStream, counter: FrameCounter) {
        stream.skipFully(10)
        val screenFlags = stream.readByte()
        stream.skipFully(2)
        if (screenFlags and 0x80 != 0) stream.skipFully(colorTableSize(screenFlags))
        while (true) {
            when (stream.read()) {
                IMAGE_DESCRIPTOR -> {
                    counter.frames++
                    stream.skipFully(8)
                    val flags = stream.readByte()
                    if (flags and 0x80 != 0) stream.skipFully(colorTableSize(flags))
                    stream.skipFully(1)
                    stream.skipSubBlocks()
                }
                EXTENSION -> {
                    stream.skipFully(1)
                    stream.skipSubBlocks()
                }
                else -> return
            }
        }
    }

    private fun countWebpFrames(stream: InputStream, counter: FrameCounter) {
        stream.skipFully(12)
        val fourCc = ByteArray(4)
        while (stream.readUpTo(fourCc) == 4) {
            val size = stream.readUInt32LittleEndian()
            when (String(fourCc, Charsets.US_ASCII)) {
                "ANMF" -> counter.frames++
                "VP8 ", "VP8L" -> if (counter.frames == 0) return
            }
            stream.skipFully(size + (size and 1))
        }
    }

    private fun countPngFrames(stream: InputStream, counter: FrameCounter) {
        stream.skipFully(8)
        val type = ByteArray(4)
        while (true) {
            val length = stream.readUInt32BigEndian()
            if (stream.readUpTo(type) < 4) return
            when (String(type, Charsets.US_ASCII)) {
                // An APNG declares its frame count before the first image data.
                "acTL" -> {
                    counter.frames = stream.readUInt32BigEndian().coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
                    return
                }
                "IDAT", "IEND" -> return
            }
            stream.skipFully(length + 4)
        }
    }

    private fun colorTableSize(flags: Int): Long = 3L shl ((flags and 0x07) + 1)

    private fun InputStream.skipSubBlocks() {
        while (true) {
            val size = readByte()
            if (size == 0) return
            skipFully(size.toLong())
        }
    }

    private fun InputStream.readByte(): Int = read().also { if (it < 0) throw EOFException() }

    private fun InputStream.readUpTo(buffer: ByteArray): Int {
        var read = 0
        while (read < buffer.size) {
            val n = read(buffer, read, buffer.size - read)
            if (n < 0) break
            read += n
        }
        return read
    }

    private fun InputStream.skipFully(count: Long) {
        var left = count
        while (left > 0) {
            val skipped = skip(left)
            if (skipped > 0) {
                left -= skipped
            } else {
                readByte()
                left--
            }
        }
    }

    private fun InputStream.readUInt32LittleEndian(): Long {
        var value = 0L
        for (shift in 0 until 32 step 8) value = value or (readByte().toLong() shl shift)
        return value
    }

    private fun InputStream.readUInt32BigEndian(): Long {
        var value = 0L
        repeat(4) { value = (value shl 8) or readByte().toLong() }
        return value
    }

    private fun ByteArray.startsWith(vararg bytes: Int): Boolean =
        size >= bytes.size && bytes.indices.all { this[it].toInt() and 0xFF == bytes[it] }

    private fun ByteArray.ascii(offset: Int, length: Int): String? =
        if (offset + length > size) null else String(this, offset, length, Charsets.US_ASCII)

    private fun ByteArray.uint32BigEndian(offset: Int): Long {
        if (offset + 4 > size) return 0
        var value = 0L
        for (i in offset until offset + 4) value = (value shl 8) or (this[i].toLong() and 0xFF)
        return value
    }
}
