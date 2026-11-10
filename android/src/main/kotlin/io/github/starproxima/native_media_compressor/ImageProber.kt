package io.github.starproxima.native_media_compressor

import android.graphics.BitmapFactory
import android.media.ExifInterface
import android.os.Build
import android.provider.MediaStore
import java.io.BufferedInputStream

internal object ImageProber {
    private val EXIF_TYPES = setOf("image/jpeg", "image/heic", "image/heif", "image/webp", "image/png")

    fun probe(source: MediaSource): ImageProbe? {
        val stored = storedSize(source) ?: return null
        val mimeType = ImageHeaders.mimeType(source.readHeader()) ?: stored.second
        val size = if (swapsSides(exifOrientation(source, mimeType))) stored.first.transposed() else stored.first
        val frames = BufferedInputStream(source.openStream()).use { ImageHeaders.frameCount(mimeType, it) }
        return ImageProbe(size.width.toLong(), size.height.toLong(), frames.toLong(), mimeType, source.sizeBytes())
    }

    /** Size of the encoded pixels before orientation, read from the header only. */
    fun storedSize(source: MediaSource): Pair<Size, String?>? {
        val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        source.openFile().use { BitmapFactory.decodeFileDescriptor(it.fileDescriptor, null, options) }
        if (options.outWidth <= 0 || options.outHeight <= 0) return null
        return Size(options.outWidth, options.outHeight) to options.outMimeType
    }

    fun exifOrientation(source: MediaSource, mimeType: String?): Int {
        if (mimeType !in EXIF_TYPES) return ExifInterface.ORIENTATION_NORMAL
        return runCatching {
            val uri = source.uri
            when {
                uri == null -> ExifInterface(source.path).orientation()
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.N ->
                    source.openFile().use { ExifInterface(it.fileDescriptor).orientation() }
                else -> mediaStoreOrientation(source)
            }
        }.getOrDefault(ExifInterface.ORIENTATION_NORMAL)
    }

    fun swapsSides(orientation: Int): Boolean = when (orientation) {
        ExifInterface.ORIENTATION_TRANSPOSE,
        ExifInterface.ORIENTATION_ROTATE_90,
        ExifInterface.ORIENTATION_TRANSVERSE,
        ExifInterface.ORIENTATION_ROTATE_270,
        -> true
        else -> false
    }

    private fun ExifInterface.orientation() =
        getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)

    // ExifInterface reads only paths before API 24; media store rows carry the rotation instead.
    private fun mediaStoreOrientation(source: MediaSource): Int {
        val uri = requireNotNull(source.uri)
        val degrees = source.contentResolver
            .query(uri, arrayOf(MediaStore.Images.ImageColumns.ORIENTATION), null, null, null)
            ?.use { if (it.moveToFirst()) it.getInt(0) else 0 } ?: 0
        return when ((degrees % 360 + 360) % 360) {
            90 -> ExifInterface.ORIENTATION_ROTATE_90
            180 -> ExifInterface.ORIENTATION_ROTATE_180
            270 -> ExifInterface.ORIENTATION_ROTATE_270
            else -> ExifInterface.ORIENTATION_NORMAL
        }
    }
}
