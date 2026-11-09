package io.github.starproxima.native_media_compressor

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.os.Build
import java.io.File
import java.io.FileOutputStream

internal object BitmapOutput {
    /** Why [format] cannot be written on this device, or null when it can. */
    fun unsupportedReason(format: ImageFormat): String? = when (format) {
        // Bitmap.compress has no HEIC, and the system HEIF writer ships only in androidx.
        ImageFormat.HEIC -> "Android has no built-in HEIC image encoder"
        else -> null
    }

    /** Encodes [bitmap] into [destination] and recycles it. */
    fun write(bitmap: Bitmap, format: ImageFormat, quality: Long, destination: File): CompressionReply {
        val compressFormat = compressFormat(format)
        if (compressFormat == null) {
            bitmap.recycle()
            return CompressionReply(CompressionStatus.UNSUPPORTED, message = unsupportedReason(format))
        }
        val encodable = encodable(bitmap, flattenAlpha = format == ImageFormat.JPEG)
        try {
            val written = FileOutputStream(destination).use { encodable.compress(compressFormat, quality.toInt().coerceIn(0, 100), it) }
            if (!written) return CompressionReply(CompressionStatus.FAILED, message = "the $compressFormat encoder failed")
            return CompressionReply(
                CompressionStatus.COMPRESSED,
                width = encodable.width.toLong(),
                height = encodable.height.toLong(),
                sizeBytes = destination.length(),
            )
        } finally {
            encodable.recycle()
        }
    }

    @Suppress("DEPRECATION")
    private fun compressFormat(format: ImageFormat): Bitmap.CompressFormat? = when (format) {
        ImageFormat.JPEG -> Bitmap.CompressFormat.JPEG
        ImageFormat.PNG -> Bitmap.CompressFormat.PNG
        // Before Android 11 there is only WEBP, lossy below quality 100 and lossless at 100.
        ImageFormat.WEBP -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Bitmap.CompressFormat.WEBP_LOSSY
        } else {
            Bitmap.CompressFormat.WEBP
        }
        ImageFormat.HEIC -> null
    }

    // JPEG has no alpha: transparent pixels would turn black without a white backdrop.
    private fun encodable(bitmap: Bitmap, flattenAlpha: Boolean): Bitmap {
        val flatten = flattenAlpha && bitmap.hasAlpha()
        if (!flatten && bitmap.config == Bitmap.Config.ARGB_8888) return bitmap
        val copy = Bitmap.createBitmap(bitmap.width, bitmap.height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(copy)
        if (flatten) canvas.drawColor(Color.WHITE)
        canvas.drawBitmap(bitmap, 0f, 0f, Paint(Paint.FILTER_BITMAP_FLAG))
        bitmap.recycle()
        return copy
    }
}
