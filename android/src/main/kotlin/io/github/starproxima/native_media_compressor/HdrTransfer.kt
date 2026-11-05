package io.github.starproxima.native_media_compressor

import android.media.MediaFormat

/** Transfer function of decoded frames, numbered as the frame shader expects. */
internal enum class HdrTransfer(val shaderCode: Int) {
    NONE(0),
    PQ(1),
    HLG(2),
    ;

    val isHdr: Boolean get() = this != NONE

    companion object {
        fun of(colorTransfer: Int?): HdrTransfer = when (colorTransfer) {
            MediaFormat.COLOR_TRANSFER_ST2084 -> PQ
            MediaFormat.COLOR_TRANSFER_HLG -> HLG
            else -> NONE
        }
    }
}
