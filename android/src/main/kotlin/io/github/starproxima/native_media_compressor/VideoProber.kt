package io.github.starproxima.native_media_compressor

import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.os.Build

internal object VideoProber {
    fun probe(source: MediaSource): VideoProbe? {
        val extractor = source.openExtractor()
        try {
            val formats = (0 until extractor.trackCount).map(extractor::getTrackFormat)
            val video = formats.firstOrNull { it.mime?.startsWith("video/") == true } ?: return null
            val audio = formats.firstOrNull { it.mime?.startsWith("audio/") == true }
            val metadata = Metadata.read(source)
            val rotation = video.intOrNull(MediaFormat.KEY_ROTATION)?.let(Rotation::normalize) ?: metadata.rotation
            val stored = Size(video.getInteger(MediaFormat.KEY_WIDTH), video.getInteger(MediaFormat.KEY_HEIGHT))
            val displayed = if (rotation % 180 != 0) stored.transposed() else stored
            val trackDurationUs = formats.maxOfOrNull { it.longOrNull(MediaFormat.KEY_DURATION) ?: 0L } ?: 0L
            return VideoProbe(
                width = displayed.width.toLong(),
                height = displayed.height.toLong(),
                rotationDegrees = rotation.toLong(),
                durationMs = metadata.durationMs ?: (trackDurationUs / 1000),
                bitrate = metadata.bitrate,
                videoCodec = video.mime,
                isHdr = video.mime == MediaFormat.MIMETYPE_VIDEO_DOLBY_VISION ||
                    HdrTransfer.of(video.intOrNull(MediaFormat.KEY_COLOR_TRANSFER) ?: metadata.colorTransfer).isHdr,
                hasAudio = audio != null,
                audioCodec = audio?.mime,
                // The frame count gives fractional rates such as 29.97 that the
                // format's whole-number rate rounds off.
                frameRate = FrameRate.average(metadata.frameCount, video.longOrNull(MediaFormat.KEY_DURATION))
                    ?: FrameRate.plausible(video.doubleOrNull(MediaFormat.KEY_FRAME_RATE)),
            )
        } finally {
            extractor.release()
        }
    }

    /** Rotation the player applies, for extractors that do not put it in the track format. */
    fun rotation(source: MediaSource, format: MediaFormat): Int =
        format.intOrNull(MediaFormat.KEY_ROTATION)?.let(Rotation::normalize) ?: Metadata.read(source).rotation

    /** Transfer function of the video track, also when only the container metadata names it. */
    fun hdrTransfer(source: MediaSource, format: MediaFormat): HdrTransfer =
        HdrTransfer.of(format.intOrNull(MediaFormat.KEY_COLOR_TRANSFER) ?: Metadata.read(source).colorTransfer)

    private class Metadata(
        val rotation: Int,
        val durationMs: Long?,
        val bitrate: Long?,
        val colorTransfer: Int?,
        val frameCount: Long?,
    ) {
        companion object {
            fun read(source: MediaSource): Metadata {
                val retriever = runCatching { source.openRetriever() }.getOrNull() ?: return Metadata(0, null, null, null, null)
                try {
                    fun value(key: Int) = retriever.extractMetadata(key)?.toLongOrNull()
                    return Metadata(
                        rotation = value(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toInt()?.let(Rotation::normalize) ?: 0,
                        durationMs = value(MediaMetadataRetriever.METADATA_KEY_DURATION)?.takeIf { it > 0 },
                        bitrate = value(MediaMetadataRetriever.METADATA_KEY_BITRATE)?.takeIf { it > 0 },
                        colorTransfer = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                            value(MediaMetadataRetriever.METADATA_KEY_COLOR_TRANSFER)?.toInt()
                        } else {
                            null
                        },
                        frameCount = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                            value(MediaMetadataRetriever.METADATA_KEY_VIDEO_FRAME_COUNT)
                        } else {
                            null
                        },
                    )
                } finally {
                    runCatching { retriever.release() }
                }
            }
        }
    }
}

internal val MediaFormat.mime: String? get() = getString(MediaFormat.KEY_MIME)

internal fun MediaFormat.intOrNull(key: String): Int? = if (!containsKey(key)) {
    null
} else {
    try {
        getInteger(key)
    } catch (_: ClassCastException) {
        getFloat(key).toInt()
    }
}

internal fun MediaFormat.doubleOrNull(key: String): Double? = if (!containsKey(key)) {
    null
} else {
    try {
        getFloat(key).toDouble()
    } catch (_: ClassCastException) {
        getInteger(key).toDouble()
    }
}

internal fun MediaFormat.longOrNull(key: String): Long? = if (!containsKey(key)) {
    null
} else {
    try {
        getLong(key)
    } catch (_: ClassCastException) {
        getInteger(key).toLong()
    }
}

internal fun MediaExtractor.tracks(mimePrefix: String): List<Int> =
    (0 until trackCount).filter { getTrackFormat(it).mime?.startsWith(mimePrefix) == true }
