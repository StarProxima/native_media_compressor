package io.github.starproxima.native_media_compressor

import android.media.ExifInterface
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

internal class ExifMetadataTest {
    private val camera = mapOf(
        ExifInterface.TAG_MAKE to "NMCTestCamera",
        ExifInterface.TAG_MODEL to "Model 1",
        ExifInterface.TAG_DATETIME_ORIGINAL to "2026:11:10 12:34:56",
        ExifInterface.TAG_GPS_LATITUDE_REF to "N",
        ExifInterface.TAG_GPS_LATITUDE to "51/1,28/1,4040/100",
        ExifInterface.TAG_ORIENTATION to ExifInterface.ORIENTATION_ROTATE_90.toString(),
        ExifInterface.TAG_PIXEL_X_DIMENSION to "4000",
        ExifInterface.TAG_PIXEL_Y_DIMENSION to "3000",
        ExifInterface.TAG_IMAGE_WIDTH to "4000",
        ExifInterface.TAG_IMAGE_LENGTH to "3000",
        ExifInterface.TAG_THUMBNAIL_IMAGE_WIDTH to "160",
        ExifInterface.TAG_JPEG_INTERCHANGE_FORMAT_LENGTH to "5000",
        ExifInterface.TAG_MAKER_NOTE to "binary",
    )

    @Test
    fun copiesTheCaptureTags() {
        val written = ExifMetadata.attributes(camera::get, Size(600, 800))

        assertEquals("NMCTestCamera", written[ExifInterface.TAG_MAKE])
        assertEquals("Model 1", written[ExifInterface.TAG_MODEL])
        assertEquals("2026:11:10 12:34:56", written[ExifInterface.TAG_DATETIME_ORIGINAL])
        assertEquals("51/1,28/1,4040/100", written[ExifInterface.TAG_GPS_LATITUDE])
    }

    @Test
    fun theOrientationIsUprightAndTheSizeIsTheOutputs() {
        val written = ExifMetadata.attributes(camera::get, Size(600, 800))

        assertEquals(ExifInterface.ORIENTATION_NORMAL.toString(), written[ExifInterface.TAG_ORIENTATION])
        assertEquals("600", written[ExifInterface.TAG_PIXEL_X_DIMENSION])
        assertEquals("800", written[ExifInterface.TAG_PIXEL_Y_DIMENSION])
    }

    @Test
    fun encodingTagsOfTheSourceAreLeftOut() {
        val written = ExifMetadata.attributes(camera::get, Size(600, 800))

        for (tag in listOf(
            ExifInterface.TAG_IMAGE_WIDTH,
            ExifInterface.TAG_IMAGE_LENGTH,
            ExifInterface.TAG_THUMBNAIL_IMAGE_WIDTH,
            ExifInterface.TAG_JPEG_INTERCHANGE_FORMAT_LENGTH,
            ExifInterface.TAG_MAKER_NOTE,
        )) {
            assertFalse(tag in written, tag)
        }
    }

    @Test
    fun aSourceWithOnlyAnOrientationGetsNothing() {
        val orientationOnly = mapOf(ExifInterface.TAG_ORIENTATION to ExifInterface.ORIENTATION_ROTATE_90.toString())

        assertTrue(ExifMetadata.attributes(orientationOnly::get, Size(600, 800)).isEmpty())
    }
}
