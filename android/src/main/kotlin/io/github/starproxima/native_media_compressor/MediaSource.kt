package io.github.starproxima.native_media_compressor

import android.content.Context
import android.content.res.AssetFileDescriptor
import android.media.MediaExtractor
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import java.io.File
import java.io.FileInputStream
import java.io.FileNotFoundException
import java.io.InputStream

/** A file path or a `content://` URI. */
internal class MediaSource(private val context: Context, private val value: String) {
    val uri: Uri? = if (value.startsWith("content://")) Uri.parse(value) else null

    val path: String get() = value

    val contentResolver get() = context.contentResolver

    fun openStream(): InputStream = uri?.let {
        context.contentResolver.openInputStream(it) ?: throw FileNotFoundException(value)
    } ?: FileInputStream(value)

    fun openFile(): ParcelFileDescriptor = uri?.let {
        context.contentResolver.openFileDescriptor(it, "r") ?: throw FileNotFoundException(value)
    } ?: ParcelFileDescriptor.open(File(value), ParcelFileDescriptor.MODE_READ_ONLY)

    fun openExtractor(): MediaExtractor {
        val extractor = MediaExtractor()
        try {
            uri?.let { extractor.setDataSource(context, it, null) } ?: extractor.setDataSource(value)
        } catch (error: Exception) {
            extractor.release()
            throw error
        }
        return extractor
    }

    fun openRetriever(): MediaMetadataRetriever {
        val retriever = MediaMetadataRetriever()
        try {
            uri?.let { retriever.setDataSource(context, it) } ?: retriever.setDataSource(value)
        } catch (error: Exception) {
            runCatching { retriever.release() }
            throw error
        }
        return retriever
    }

    /** Byte size of the source, null when the provider does not tell it. */
    fun sizeBytes(): Long? = runCatching {
        val uri = uri ?: return@runCatching File(value).takeIf(File::isFile)?.length()
        val column = context.contentResolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use {
            if (it.moveToFirst() && !it.isNull(0)) it.getLong(0) else null
        }
        // Providers may leave the column empty; the descriptor knows the length of a plain file.
        column?.takeIf { it >= 0 } ?: context.contentResolver.openAssetFileDescriptor(uri, "r")?.use { descriptor ->
            descriptor.length.takeIf { it != AssetFileDescriptor.UNKNOWN_LENGTH && it >= 0 }
                ?: descriptor.parcelFileDescriptor.statSize.takeIf { it >= 0 }
        }
    }.getOrNull()

    /** Reads at most [count] bytes from the start. */
    fun readHeader(count: Int = 64): ByteArray = openStream().use { stream ->
        val buffer = ByteArray(count)
        var read = 0
        while (read < count) {
            val n = stream.read(buffer, read, count - read)
            if (n < 0) break
            read += n
        }
        buffer.copyOf(read)
    }
}
