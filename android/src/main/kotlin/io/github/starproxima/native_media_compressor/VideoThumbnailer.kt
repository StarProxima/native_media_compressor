package io.github.starproxima.native_media_compressor

import android.graphics.Bitmap
import android.graphics.Matrix
import android.media.MediaMetadataRetriever
import android.os.Build
import java.io.File
import java.io.IOException

/** Saves one frame of a video as an image, in the orientation the player shows. */
internal class VideoThumbnailer(private val source: MediaSource, private val request: ThumbnailRequest) {
    fun run(): CompressionReply {
        val output = try {
            StagedOutput.create(request.destination)
        } catch (error: IOException) {
            return CompressionReply(CompressionStatus.FAILED, message = error.toString())
        }
        var reply = CompressionReply(CompressionStatus.FAILED)
        try {
            reply = capture(output.file)
        } catch (error: Exception) {
            reply = CompressionReply(CompressionStatus.FAILED, message = error.toString())
        } catch (error: OutOfMemoryError) {
            reply = CompressionReply(CompressionStatus.FAILED, message = error.toString())
        } finally {
            if (reply.status != CompressionStatus.COMPRESSED) output.discard()
        }
        return output.finish(reply)
    }

    private fun capture(destination: File): CompressionReply {
        val retriever = try {
            source.openRetriever()
        } catch (error: Exception) {
            return CompressionReply(CompressionStatus.UNSUPPORTED, message = "cannot read the video: $error")
        }
        try {
            fun value(key: Int) = retriever.extractMetadata(key)?.toLongOrNull()
            if (retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_VIDEO) != "yes") {
                return CompressionReply(CompressionStatus.UNSUPPORTED, message = "no video track")
            }
            val width = value(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toInt()
            val height = value(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toInt()
            if (width == null || height == null || width <= 0 || height <= 0) {
                return CompressionReply(CompressionStatus.FAILED, message = "the video has no frame size")
            }
            val rotation = Rotation.normalize(value(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toInt() ?: 0)
            val stored = Size(width, height)
            val displayed = stored.rotated(rotation)
            val target = Scaling.imageSize(displayed, request.maxShortSide, request.maxLongSide)
            val durationUs = value(MediaMetadataRetriever.METADATA_KEY_DURATION)?.takeIf { it > 0 }?.times(1000)
            val positionUs = request.positionMs.coerceAtLeast(0) * 1000
            val timeUs = durationUs?.let { minOf(positionUs, it) } ?: positionUs
            val frame = frameAt(retriever, timeUs, target)
                ?: return CompressionReply(CompressionStatus.FAILED, message = "cannot decode a frame at ${timeUs / 1000} ms")
            return BitmapOutput.write(fit(frame, stored, rotation, target), request.format, request.quality, destination)
        } finally {
            runCatching { retriever.release() }
        }
    }

    /**
     * The frame shown at [timeUs], or the closest one the retriever finds. Past the
     * last frame some versions find nothing exact, so a sync frame is the fallback.
     */
    private fun frameAt(retriever: MediaMetadataRetriever, timeUs: Long, target: Size): Bitmap? {
        // The box is square because the retriever may fit the stored frame or the
        // turned one into it; fit() brings the result to the exact target.
        val box = maxOf(target.width, target.height)
        val options = listOf(MediaMetadataRetriever.OPTION_CLOSEST, MediaMetadataRetriever.OPTION_PREVIOUS_SYNC)
        for (option in options) {
            val frame = runCatching {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                    retriever.getScaledFrameAtTime(timeUs, option, box, box)
                } else {
                    retriever.getFrameAtTime(timeUs, option)
                }
            }.getOrNull()
            if (frame != null) return frame
        }
        return null
    }

    /** Turns [frame] to the displayed orientation when the retriever has not, and scales it to [target]. */
    private fun fit(frame: Bitmap, stored: Size, rotation: Int, target: Size): Bitmap {
        val isLandscape = { size: Size -> size.width > size.height }
        val frameSize = Size(frame.width, frame.height)
        val isStillStored = rotation % 180 != 0 && stored.width != stored.height &&
            isLandscape(frameSize) == isLandscape(stored)
        val matrix = Matrix()
        if (isStillStored) matrix.postRotate(rotation.toFloat())
        val turned = if (isStillStored) frameSize.transposed() else frameSize
        if (turned != target) matrix.postScale(target.width.toFloat() / turned.width, target.height.toFloat() / turned.height)
        if (matrix.isIdentity) return frame
        return Bitmap.createBitmap(frame, 0, 0, frame.width, frame.height, matrix, true)
            .also { if (it !== frame) frame.recycle() }
    }
}
