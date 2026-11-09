package io.github.starproxima.native_media_compressor

import android.media.ExifInterface
import android.os.Build
import android.annotation.TargetApi
import java.io.File
import java.io.IOException

/** Carries the EXIF tags of a source image over to its re-encoded output. */
internal object ExifMetadata {
    /**
     * Tags about the capture rather than the encoding, so they stay true for a
     * scaled re-encode. Binary tags (maker notes, user comments, version
     * bytes) are left out: ExifInterface hands them over as text and would
     * write them back mangled.
     */
    val COPIED_TAGS = listOf(
        ExifInterface.TAG_MAKE,
        ExifInterface.TAG_MODEL,
        ExifInterface.TAG_SOFTWARE,
        ExifInterface.TAG_ARTIST,
        ExifInterface.TAG_COPYRIGHT,
        ExifInterface.TAG_IMAGE_DESCRIPTION,
        ExifInterface.TAG_DATETIME,
        ExifInterface.TAG_DATETIME_ORIGINAL,
        ExifInterface.TAG_DATETIME_DIGITIZED,
        ExifInterface.TAG_OFFSET_TIME,
        ExifInterface.TAG_OFFSET_TIME_ORIGINAL,
        ExifInterface.TAG_OFFSET_TIME_DIGITIZED,
        ExifInterface.TAG_SUBSEC_TIME,
        ExifInterface.TAG_SUBSEC_TIME_ORIGINAL,
        ExifInterface.TAG_SUBSEC_TIME_DIGITIZED,
        ExifInterface.TAG_EXPOSURE_TIME,
        ExifInterface.TAG_F_NUMBER,
        ExifInterface.TAG_EXPOSURE_PROGRAM,
        ExifInterface.TAG_ISO_SPEED_RATINGS,
        ExifInterface.TAG_SHUTTER_SPEED_VALUE,
        ExifInterface.TAG_APERTURE_VALUE,
        ExifInterface.TAG_BRIGHTNESS_VALUE,
        ExifInterface.TAG_EXPOSURE_BIAS_VALUE,
        ExifInterface.TAG_MAX_APERTURE_VALUE,
        ExifInterface.TAG_SUBJECT_DISTANCE,
        ExifInterface.TAG_METERING_MODE,
        ExifInterface.TAG_LIGHT_SOURCE,
        ExifInterface.TAG_FLASH,
        ExifInterface.TAG_FOCAL_LENGTH,
        ExifInterface.TAG_FOCAL_LENGTH_IN_35MM_FILM,
        ExifInterface.TAG_EXPOSURE_INDEX,
        ExifInterface.TAG_SENSING_METHOD,
        ExifInterface.TAG_CUSTOM_RENDERED,
        ExifInterface.TAG_EXPOSURE_MODE,
        ExifInterface.TAG_WHITE_BALANCE,
        ExifInterface.TAG_DIGITAL_ZOOM_RATIO,
        ExifInterface.TAG_SCENE_CAPTURE_TYPE,
        ExifInterface.TAG_GAIN_CONTROL,
        ExifInterface.TAG_CONTRAST,
        ExifInterface.TAG_SATURATION,
        ExifInterface.TAG_SHARPNESS,
        ExifInterface.TAG_SUBJECT_DISTANCE_RANGE,
        ExifInterface.TAG_IMAGE_UNIQUE_ID,
        ExifInterface.TAG_GPS_LATITUDE_REF,
        ExifInterface.TAG_GPS_LATITUDE,
        ExifInterface.TAG_GPS_LONGITUDE_REF,
        ExifInterface.TAG_GPS_LONGITUDE,
        ExifInterface.TAG_GPS_ALTITUDE_REF,
        ExifInterface.TAG_GPS_ALTITUDE,
        ExifInterface.TAG_GPS_TIMESTAMP,
        ExifInterface.TAG_GPS_DATESTAMP,
        ExifInterface.TAG_GPS_SATELLITES,
        ExifInterface.TAG_GPS_STATUS,
        ExifInterface.TAG_GPS_MEASURE_MODE,
        ExifInterface.TAG_GPS_DOP,
        ExifInterface.TAG_GPS_SPEED_REF,
        ExifInterface.TAG_GPS_SPEED,
        ExifInterface.TAG_GPS_TRACK_REF,
        ExifInterface.TAG_GPS_TRACK,
        ExifInterface.TAG_GPS_IMG_DIRECTION_REF,
        ExifInterface.TAG_GPS_IMG_DIRECTION,
        ExifInterface.TAG_GPS_MAP_DATUM,
        ExifInterface.TAG_GPS_DEST_LATITUDE_REF,
        ExifInterface.TAG_GPS_DEST_LATITUDE,
        ExifInterface.TAG_GPS_DEST_LONGITUDE_REF,
        ExifInterface.TAG_GPS_DEST_LONGITUDE,
        ExifInterface.TAG_GPS_DEST_BEARING_REF,
        ExifInterface.TAG_GPS_DEST_BEARING,
        ExifInterface.TAG_GPS_DEST_DISTANCE_REF,
        ExifInterface.TAG_GPS_DEST_DISTANCE,
        ExifInterface.TAG_GPS_DIFFERENTIAL,
    )

    /**
     * The tags to write into an output of [size]: the copied tags [read] from
     * the source, an upright orientation because the pixels are already turned,
     * and the output's pixel size. Empty when the source has none of the tags.
     */
    fun attributes(read: (String) -> String?, size: Size): Map<String, String> {
        val copied = COPIED_TAGS.mapNotNull { tag -> read(tag)?.let { tag to it } }
        if (copied.isEmpty()) return emptyMap()
        return copied.toMap() + mapOf(
            ExifInterface.TAG_ORIENTATION to ExifInterface.ORIENTATION_NORMAL.toString(),
            ExifInterface.TAG_PIXEL_X_DIMENSION to size.width.toString(),
            ExifInterface.TAG_PIXEL_Y_DIMENSION to size.height.toString(),
        )
    }

    /**
     * Whether ExifInterface can write [format] here. JPEG writing before
     * Android 7 goes through an old native path that loses tags; PNG and WebP
     * writing came with Android 11.
     */
    fun canWrite(format: ImageFormat): Boolean = when (format) {
        ImageFormat.JPEG -> Build.VERSION.SDK_INT >= Build.VERSION_CODES.N
        ImageFormat.PNG, ImageFormat.WEBP -> Build.VERSION.SDK_INT >= Build.VERSION_CODES.R
        ImageFormat.HEIC -> false
    }

    /**
     * Writes the metadata of [source] into [destination], an encoded image of
     * [size]. Does nothing when the source has no metadata ExifInterface reads.
     */
    @TargetApi(Build.VERSION_CODES.N)
    @Throws(IOException::class)
    fun copy(source: MediaSource, destination: File, size: Size) {
        val sourceExif = read(source) ?: return
        val attributes = attributes(sourceExif::getAttribute, size)
        if (attributes.isEmpty()) return
        val output = ExifInterface(destination.path)
        for ((tag, value) in attributes) {
            // A value this version cannot parse loses only its own tag.
            runCatching { output.setAttribute(tag, value) }
        }
        output.saveAttributes()
    }

    @TargetApi(Build.VERSION_CODES.N)
    private fun read(source: MediaSource): ExifInterface? = runCatching {
        if (source.uri == null) {
            ExifInterface(source.path)
        } else {
            source.openFile().use { ExifInterface(it.fileDescriptor) }
        }
    }.getOrNull()
}
