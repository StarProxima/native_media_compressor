package io.github.starproxima.native_media_compressor

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import java.io.File
import java.io.FileOutputStream

internal object BitmapOutput {
    /** Encodes [bitmap] into [destination] and recycles it. */
    fun write(bitmap: Bitmap, format: ImageFormat, quality: Long, destination: File): CompressionReply {
        val isJpeg = format == ImageFormat.JPEG
        val encodable = encodable(bitmap, flattenAlpha = isJpeg)
        try {
            val compressFormat = if (isJpeg) Bitmap.CompressFormat.JPEG else Bitmap.CompressFormat.PNG
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
