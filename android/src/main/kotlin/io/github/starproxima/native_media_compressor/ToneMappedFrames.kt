package io.github.starproxima.native_media_compressor

import android.media.Image
import android.media.MediaFormat
import android.opengl.GLES20
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer

/**
 * Draws HDR frames decoded into buffers onto the current EGL surface as SDR.
 *
 * Sampling the decoder's surface would leave the YUV to RGB conversion of 10-bit
 * frames to the driver, which many devices cannot do, so the planes are uploaded
 * as they are and the shader reads the samples itself.
 */
internal class ToneMappedFrames(private val width: Int, private val height: Int, var transfer: HdrTransfer) {
    private var isFullRange = false
    private val program = GlProgram.create(VERTEX_SHADER, FRAGMENT_SHADER)
    private val positionHandle = GLES20.glGetAttribLocation(program, "aPosition")
    private val texCoordHandle = GLES20.glGetAttribLocation(program, "aTexCoord")
    private val transferHandle = GLES20.glGetUniformLocation(program, "uTransfer")
    private val fullRangeHandle = GLES20.glGetUniformLocation(program, "uFullRange")
    init {
        GLES20.glUseProgram(program)
    }

    private val planes = listOf("Y", "U", "V").mapIndexed { unit, name -> PlaneTexture(program, unit, name) }
    private val quad: FloatBuffer = ByteBuffer.allocateDirect(QUAD.size * 4)
        .order(ByteOrder.nativeOrder()).asFloatBuffer().apply { put(QUAD).position(0) }

    fun onOutputFormat(format: MediaFormat) {
        format.intOrNull(MediaFormat.KEY_COLOR_RANGE)?.let { isFullRange = it == MediaFormat.COLOR_RANGE_FULL }
        HdrTransfer.of(format.intOrNull(MediaFormat.KEY_COLOR_TRANSFER)).takeIf { it.isHdr }?.let { transfer = it }
    }

    fun draw(image: Image) {
        val crop = image.cropRect
        // 10-bit layouts (P010 and the like) keep each sample in 16 bits; the luma
        // plane's pixel stride tells them apart from 8-bit ones.
        val sampleBytes = if (image.planes[0].pixelStride >= 2) 2 else 1
        val luma = Size(crop.width(), crop.height())
        val chroma = Size((crop.width() + 1) / 2, (crop.height() + 1) / 2)
        GLES20.glUseProgram(program)
        planes[0].upload(image.planes[0], crop.left, crop.top, luma, sampleBytes)
        planes[1].upload(image.planes[1], crop.left / 2, crop.top / 2, chroma, sampleBytes)
        planes[2].upload(image.planes[2], crop.left / 2, crop.top / 2, chroma, sampleBytes)
        GLES20.glViewport(0, 0, width, height)
        GLES20.glUniform1i(transferHandle, transfer.shaderCode)
        GLES20.glUniform1f(fullRangeHandle, if (isFullRange) 1f else 0f)
        quad.position(0)
        GLES20.glVertexAttribPointer(positionHandle, 2, GLES20.GL_FLOAT, false, STRIDE, quad)
        GLES20.glEnableVertexAttribArray(positionHandle)
        quad.position(2)
        GLES20.glVertexAttribPointer(texCoordHandle, 2, GLES20.GL_FLOAT, false, STRIDE, quad)
        GLES20.glEnableVertexAttribArray(texCoordHandle)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        check(GLES20.glGetError() == GLES20.GL_NO_ERROR) { "GL draw failed" }
    }

    fun release() {
        GLES20.glDeleteProgram(program)
        planes.forEach { it.release() }
    }

    /**
     * One image plane as a texture whose texels are the plane's pixels, padding
     * included: a 4-byte P010 chroma pixel becomes an RGBA texel. [weights] turn a
     * texel back into the sample, so no byte has to be rearranged on the CPU.
     */
    private class PlaneTexture(program: Int, private val unit: Int, name: String) {
        private val id = IntArray(1).also { GLES20.glGenTextures(1, it, 0) }[0]
        private val sizeHandle = GLES20.glGetUniformLocation(program, "u${name}Size")
        private val weightsHandle = GLES20.glGetUniformLocation(program, "u${name}Weights")
        private var staging = ByteBuffer.allocateDirect(0)

        init {
            GLES20.glUniform1i(GLES20.glGetUniformLocation(program, "s$name"), unit)
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, id)
            // Linear filtering would blend the high and low bytes of 16-bit samples
            // separately, so the shader interpolates whole samples itself.
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_NEAREST)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_NEAREST)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
        }

        fun upload(plane: Image.Plane, left: Int, top: Int, size: Size, sampleBytes: Int) {
            val texelBytes = plane.pixelStride
            val format = when (texelBytes) {
                1 -> GLES20.GL_LUMINANCE
                2 -> GLES20.GL_LUMINANCE_ALPHA
                4 -> GLES20.GL_RGBA
                else -> error("unsupported pixel stride $texelBytes")
            }
            // Texture channels hold byte / 255; a 16-bit little-endian sample is
            // low + 256 * high over 65535, with the high byte in the second channel.
            val high = if (format == GLES20.GL_LUMINANCE_ALPHA) 3 else 1
            val weights = FloatArray(4)
            if (sampleBytes == 1) {
                weights[0] = 1f
            } else {
                weights[0] = 255f / 65535f
                weights[high] = 65280f / 65535f
            }
            GLES20.glUniform4fv(weightsHandle, 1, weights, 0)
            GLES20.glUniform2f(sizeHandle, size.width.toFloat(), size.height.toFloat())
            GLES20.glActiveTexture(GLES20.GL_TEXTURE0 + unit)
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, id)
            GLES20.glPixelStorei(GLES20.GL_UNPACK_ALIGNMENT, 1)
            GLES20.glTexImage2D(
                GLES20.GL_TEXTURE_2D, 0, format, size.width, size.height, 0, format, GLES20.GL_UNSIGNED_BYTE,
                packedRows(plane, left, top, size, texelBytes),
            )
        }

        /**
         * Rows of the visible area without the stride padding, which OpenGL ES 2 cannot
         * skip. They are always copied: handing the codec's own buffer to the driver
         * hangs on some (emulated) GPUs.
         */
        private fun packedRows(plane: Image.Plane, left: Int, top: Int, size: Size, texelBytes: Int): ByteBuffer {
            val source = plane.buffer.duplicate()
            val rowBytes = size.width * texelBytes
            if (staging.capacity() != rowBytes * size.height) staging = ByteBuffer.allocateDirect(rowBytes * size.height)
            staging.clear()
            for (row in 0 until size.height) {
                val start = (top + row) * plane.rowStride + left * texelBytes
                // The last row of an interleaved chroma plane ends at its last own
                // sample, short of the full pixel stride.
                val length = minOf(rowBytes, source.capacity() - start)
                source.limit(start + length).position(start)
                staging.put(source)
                source.limit(source.capacity())
                repeat(rowBytes - length) { staging.put(0.toByte()) }
            }
            return staging.flip() as ByteBuffer
        }

        fun release() = GLES20.glDeleteTextures(1, intArrayOf(id), 0)
    }

    private companion object {
        const val STRIDE = 4 * 4

        // x, y, u, v of a full-frame triangle strip; v runs top to bottom because
        // image rows are uploaded top first.
        val QUAD = floatArrayOf(
            -1f, -1f, 0f, 1f,
            1f, -1f, 1f, 1f,
            -1f, 1f, 0f, 0f,
            1f, 1f, 1f, 0f,
        )

        const val VERTEX_SHADER = """
            attribute vec4 aPosition;
            attribute vec2 aTexCoord;
            varying vec2 vTexCoord;
            void main() {
                gl_Position = aPosition;
                vTexCoord = aTexCoord;
            }
        """

        // BT.2020 YUV becomes RGB still encoded with PQ or HLG, then display light
        // in nits. The brightest channel goes through the BT.2390 EETF from a
        // 1000-nit source (the usual PQ mastering level and the HLG reference
        // display) to a 100-nit SDR white: shadows and mid-tones stay as they are,
        // only highlights are compressed, and scaling all channels alike keeps hues.
        // Then BT.709 primaries and the BT.709 transfer function.
        const val FRAGMENT_SHADER = """
            #ifdef GL_FRAGMENT_PRECISION_HIGH
            precision highp float;
            #else
            precision mediump float;
            #endif
            varying vec2 vTexCoord;
            uniform sampler2D sY;
            uniform sampler2D sU;
            uniform sampler2D sV;
            uniform vec2 uYSize;
            uniform vec2 uUSize;
            uniform vec2 uVSize;
            uniform vec4 uYWeights;
            uniform vec4 uUWeights;
            uniform vec4 uVWeights;
            uniform int uTransfer;
            uniform float uFullRange;

            const float SOURCE_PEAK = 1000.0;
            const float SDR_WHITE = 100.0;
            const float M1 = 0.1593017578125;
            const float M2 = 78.84375;
            const float C1 = 0.8359375;
            const float C2 = 18.8515625;
            const float C3 = 18.6875;
            const mat3 BT2020_TO_BT709 = mat3(
                1.6605, -0.1246, -0.0182,
                -0.5876, 1.1329, -0.1006,
                -0.0728, -0.0083, 1.1187);

            float bilinear(sampler2D plane, vec4 weights, vec2 size, vec2 uv) {
                vec2 position = uv * size - 0.5;
                vec2 f = fract(position);
                vec2 base = (floor(position) + 0.5) / size;
                vec2 texel = 1.0 / size;
                float a = dot(texture2D(plane, base), weights);
                float b = dot(texture2D(plane, base + vec2(texel.x, 0.0)), weights);
                float c = dot(texture2D(plane, base + vec2(0.0, texel.y)), weights);
                float d = dot(texture2D(plane, base + texel), weights);
                return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
            }

            vec3 pqToNits(vec3 e) {
                vec3 p = pow(e, vec3(1.0 / M2));
                return pow(max(p - C1, 0.0) / (C2 - C3 * p), vec3(1.0 / M1)) * 10000.0;
            }

            float nitsToPq(float nits) {
                float y = pow(nits / 10000.0, M1);
                return pow((C1 + C2 * y) / (1.0 + C3 * y), M2);
            }

            float pqToNits(float e) {
                float p = pow(e, 1.0 / M2);
                return pow(max(p - C1, 0.0) / (C2 - C3 * p), 1.0 / M1) * 10000.0;
            }

            // HLG inverse OETF and the BT.2100 OOTF for a 1000-nit display (gamma 1.2).
            vec3 hlgToNits(vec3 e) {
                vec3 scene = mix(e * e / 3.0, (exp((e - 0.55991073) / 0.17883277) + 0.28466892) / 12.0, step(0.5, e));
                float sceneLuma = dot(scene, vec3(0.2627, 0.6780, 0.0593));
                return scene * pow(max(sceneLuma, 1e-6), 0.2) * SOURCE_PEAK;
            }

            float eetf(float nits) {
                float sourcePeak = nitsToPq(SOURCE_PEAK);
                float maxLum = nitsToPq(SDR_WHITE) / sourcePeak;
                float kneeStart = 1.5 * maxLum - 0.5;
                float e = nitsToPq(nits) / sourcePeak;
                if (e > kneeStart) {
                    float t = min((e - kneeStart) / (1.0 - kneeStart), 1.0);
                    float t2 = t * t;
                    float t3 = t2 * t;
                    e = (2.0 * t3 - 3.0 * t2 + 1.0) * kneeStart + (t3 - 2.0 * t2 + t) * (1.0 - kneeStart)
                        + (-2.0 * t3 + 3.0 * t2) * maxLum;
                }
                return pqToNits(e * sourcePeak);
            }

            vec3 bt709Oetf(vec3 l) {
                return mix(4.5 * l, 1.099 * pow(l, vec3(0.45)) - 0.099, step(0.018, l));
            }

            void main() {
                float y = bilinear(sY, uYWeights, uYSize, vTexCoord);
                vec2 c = vec2(bilinear(sU, uUWeights, uUSize, vTexCoord), bilinear(sV, uVWeights, uVSize, vTexCoord));
                if (uFullRange > 0.5) {
                    c -= 0.5;
                } else {
                    y = (y - 16.0 / 255.0) / (219.0 / 255.0);
                    c = (c - 128.0 / 255.0) / (224.0 / 255.0);
                }
                vec3 e = clamp(vec3(y + 1.4746 * c.y, y - 0.16455 * c.x - 0.57135 * c.y, y + 1.8814 * c.x), 0.0, 1.0);
                vec3 nits = uTransfer == 1 ? pqToNits(e) : hlgToNits(e);
                float signal = max(max(nits.r, nits.g), max(nits.b, 1e-3));
                vec3 sdr = nits * (eetf(signal) / signal / SDR_WHITE);
                gl_FragColor = vec4(bt709Oetf(clamp(BT2020_TO_BT709 * sdr, 0.0, 1.0)), 1.0);
            }
        """
    }
}
