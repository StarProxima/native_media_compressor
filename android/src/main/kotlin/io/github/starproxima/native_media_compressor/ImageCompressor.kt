package io.github.starproxima.native_media_compressor

import android.annotation.TargetApi
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.media.ExifInterface
import android.os.Build
import java.io.File
import java.io.IOException

internal class ImageCompressor(private val source: MediaSource, private val request: ImageRequest) {
    fun run(): CompressionReply {
        val output = try {
            StagedOutput.create(request.destination)
        } catch (error: IOException) {
            return CompressionReply(CompressionStatus.FAILED, message = error.toString())
        }
        var reply = CompressionReply(CompressionStatus.FAILED)
        try {
            reply = compress(output.file)
        } catch (error: IOException) {
            reply = CompressionReply(CompressionStatus.FAILED, message = error.toString())
        } catch (error: OutOfMemoryError) {
            reply = CompressionReply(CompressionStatus.FAILED, message = error.toString())
        } finally {
            if (reply.status != CompressionStatus.COMPRESSED) output.discard()
        }
        return output.finish(reply)
    }

    private fun compress(destination: File): CompressionReply {
        val mimeType = ImageHeaders.mimeType(source.readHeader())
        val decoded = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) decodeWithImageDecoder() else decodeWithBitmapFactory(mimeType)
        } catch (error: IOException) {
            val status = if (cannotDecode(mimeType)) CompressionStatus.UNSUPPORTED else CompressionStatus.FAILED
            return CompressionReply(status, message = "${mimeType ?: "unknown format"}: $error")
        }
        return BitmapOutput.write(decoded, request.format, request.quality, destination)
    }

    @TargetApi(Build.VERSION_CODES.P)
    private fun decodeWithImageDecoder(): Bitmap {
        val decoderSource = source.uri?.let { ImageDecoder.createSource(source.contentResolver, it) }
            ?: ImageDecoder.createSource(File(source.path))
        // ImageDecoder reports and produces the size after EXIF orientation and
        // samples down while decoding, so a large photo never exists at full size.
        return ImageDecoder.decodeBitmap(decoderSource) { decoder, info, _ ->
            val target = Scaling.imageSize(Size(info.size.width, info.size.height), request.maxShortSide, request.maxLongSide)
            decoder.setTargetSize(target.width, target.height)
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
        }
    }

    private fun decodeWithBitmapFactory(mimeType: String?): Bitmap {
        val stored = ImageProber.storedSize(source)?.first ?: throw IOException("cannot read the image header")
        val orientation = ImageProber.exifOrientation(source, mimeType)
        val swaps = ImageProber.swapsSides(orientation)
        val displayed = if (swaps) stored.transposed() else stored
        val target = Scaling.imageSize(displayed, request.maxShortSide, request.maxLongSide)
            .let { if (swaps) it.transposed() else it }
        val options = BitmapFactory.Options().apply { inSampleSize = sampleSize(stored, target) }
        val sampled = source.openFile().use { BitmapFactory.decodeFileDescriptor(it.fileDescriptor, null, options) }
            ?: throw IOException("cannot decode the image")
        val scaled = if (sampled.width == target.width && sampled.height == target.height) {
            sampled
        } else {
            Bitmap.createScaledBitmap(sampled, target.width, target.height, true).also { if (it !== sampled) sampled.recycle() }
        }
        val matrix = orientationMatrix(orientation) ?: return scaled
        return Bitmap.createBitmap(scaled, 0, 0, scaled.width, scaled.height, matrix, true)
            .also { if (it !== scaled) scaled.recycle() }
    }

    private fun cannotDecode(mimeType: String?): Boolean = when (mimeType) {
        "image/heic", "image/heif" -> Build.VERSION.SDK_INT < Build.VERSION_CODES.P
        "image/avif" -> Build.VERSION.SDK_INT < Build.VERSION_CODES.S
        "image/tiff" -> true
        else -> false
    }

    private companion object {
        fun sampleSize(stored: Size, target: Size): Int {
            var sample = 1
            while (stored.width / (sample * 2) >= target.width && stored.height / (sample * 2) >= target.height) {
                sample *= 2
            }
            return sample
        }

        fun orientationMatrix(orientation: Int): Matrix? {
            val matrix = Matrix()
            when (orientation) {
                ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.setScale(-1f, 1f)
                ExifInterface.ORIENTATION_ROTATE_180 -> matrix.setRotate(180f)
                ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.setScale(1f, -1f)
                ExifInterface.ORIENTATION_TRANSPOSE -> matrix.apply { setRotate(90f); postScale(-1f, 1f) }
                ExifInterface.ORIENTATION_ROTATE_90 -> matrix.setRotate(90f)
                ExifInterface.ORIENTATION_TRANSVERSE -> matrix.apply { setRotate(-90f); postScale(-1f, 1f) }
                ExifInterface.ORIENTATION_ROTATE_270 -> matrix.setRotate(-90f)
                else -> return null
            }
            return matrix
        }
    }
}
