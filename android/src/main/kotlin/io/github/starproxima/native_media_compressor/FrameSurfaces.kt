package io.github.starproxima.native_media_compressor

import android.graphics.SurfaceTexture
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.os.Handler
import android.os.HandlerThread
import android.view.Surface
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/** EGL context over the encoder's input surface: whatever is drawn in it becomes an encoder frame. */
internal class InputSurface(private val surface: Surface) {
    private val display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
    private val context: EGLContext
    private val eglSurface: EGLSurface

    init {
        check(display != EGL14.EGL_NO_DISPLAY) { "no EGL display" }
        val version = IntArray(2)
        check(EGL14.eglInitialize(display, version, 0, version, 1)) { "EGL initialize failed" }
        val attributes = intArrayOf(
            EGL14.EGL_RED_SIZE, 8,
            EGL14.EGL_GREEN_SIZE, 8,
            EGL14.EGL_BLUE_SIZE, 8,
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
            EGLExt.EGL_RECORDABLE_ANDROID, 1,
            EGL14.EGL_NONE,
        )
        val configs = arrayOfNulls<EGLConfig>(1)
        val count = IntArray(1)
        check(EGL14.eglChooseConfig(display, attributes, 0, configs, 0, 1, count, 0) && count[0] > 0) {
            "no recordable EGL config"
        }
        context = EGL14.eglCreateContext(
            display, configs[0], EGL14.EGL_NO_CONTEXT,
            intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE), 0,
        )
        check(context != EGL14.EGL_NO_CONTEXT) { "EGL context failed" }
        eglSurface = EGL14.eglCreateWindowSurface(display, configs[0], surface, intArrayOf(EGL14.EGL_NONE), 0)
        check(eglSurface != EGL14.EGL_NO_SURFACE) { "EGL surface failed" }
    }

    fun makeCurrent() = check(EGL14.eglMakeCurrent(display, eglSurface, eglSurface, context)) { "EGL make current failed" }

    fun swapBuffers() = check(EGL14.eglSwapBuffers(display, eglSurface)) { "EGL swap failed" }

    fun setPresentationTime(nanoseconds: Long) {
        EGLExt.eglPresentationTimeANDROID(display, eglSurface, nanoseconds)
    }

    fun release() {
        EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
        EGL14.eglDestroySurface(display, eglSurface)
        EGL14.eglDestroyContext(display, context)
        EGL14.eglReleaseThread()
        EGL14.eglTerminate(display)
        surface.release()
    }
}

/**
 * Surface the decoder renders into: each decoded frame lands in a texture and is
 * drawn into the current EGL context at [width] x [height], which scales it.
 */
internal class OutputSurface(private val width: Int, private val height: Int) {
    // Without its own looper the frame-available callback would go to the main
    // thread, which must never wait for compression.
    private val thread = HandlerThread("native-media-compressor-frames").apply { start() }
    private val lock = ReentrantLock()
    private val frameArrived = lock.newCondition()
    private var isFrameAvailable = false
    private val renderer = TextureRenderer()
    private val texture = SurfaceTexture(renderer.textureId).apply {
        setOnFrameAvailableListener({
            lock.withLock {
                isFrameAvailable = true
                frameArrived.signalAll()
            }
        }, Handler(thread.looper))
    }
    val surface = Surface(texture)

    fun awaitNewImage() {
        lock.withLock {
            var leftNs = TimeUnit.MILLISECONDS.toNanos(FRAME_TIMEOUT_MS)
            while (!isFrameAvailable) {
                check(leftNs > 0) { "decoded frame did not arrive" }
                leftNs = frameArrived.awaitNanos(leftNs)
            }
            isFrameAvailable = false
        }
        texture.updateTexImage()
    }

    fun drawImage() = renderer.draw(texture, width, height)

    fun release() {
        surface.release()
        texture.release()
        renderer.release()
        thread.quitSafely()
    }

    private companion object {
        const val FRAME_TIMEOUT_MS = 2_500L
    }
}

private class TextureRenderer {
    val textureId: Int
    private val program: Int
    private val positionHandle: Int
    private val texCoordHandle: Int
    private val matrixHandle: Int
    private val matrix = FloatArray(16)
    private val quad: FloatBuffer = ByteBuffer.allocateDirect(QUAD.size * 4)
        .order(ByteOrder.nativeOrder()).asFloatBuffer().apply { put(QUAD).position(0) }

    init {
        program = GlProgram.create(VERTEX_SHADER, FRAGMENT_SHADER)
        positionHandle = GLES20.glGetAttribLocation(program, "aPosition")
        texCoordHandle = GLES20.glGetAttribLocation(program, "aTexCoord")
        matrixHandle = GLES20.glGetUniformLocation(program, "uTexMatrix")
        val textures = IntArray(1)
        GLES20.glGenTextures(1, textures, 0)
        textureId = textures[0]
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, textureId)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
    }

    fun draw(texture: SurfaceTexture, width: Int, height: Int) {
        texture.getTransformMatrix(matrix)
        GLES20.glViewport(0, 0, width, height)
        GLES20.glUseProgram(program)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, textureId)
        GLES20.glUniformMatrix4fv(matrixHandle, 1, false, matrix, 0)
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
        GLES20.glDeleteTextures(1, intArrayOf(textureId), 0)
    }

    private companion object {
        const val STRIDE = 4 * 4

        // x, y, u, v of a full-frame triangle strip.
        val QUAD = floatArrayOf(
            -1f, -1f, 0f, 0f,
            1f, -1f, 1f, 0f,
            -1f, 1f, 0f, 1f,
            1f, 1f, 1f, 1f,
        )

        const val VERTEX_SHADER = """
            uniform mat4 uTexMatrix;
            attribute vec4 aPosition;
            attribute vec4 aTexCoord;
            varying vec2 vTexCoord;
            void main() {
                gl_Position = aPosition;
                vTexCoord = (uTexMatrix * aTexCoord).xy;
            }
        """

        const val FRAGMENT_SHADER = """
            #extension GL_OES_EGL_image_external : require
            precision mediump float;
            varying vec2 vTexCoord;
            uniform samplerExternalOES sTexture;
            void main() {
                gl_FragColor = texture2D(sTexture, vTexCoord);
            }
        """
    }
}

internal object GlProgram {
    fun create(vertexShader: String, fragmentShader: String): Int {
        val program = GLES20.glCreateProgram()
        GLES20.glAttachShader(program, compile(GLES20.GL_VERTEX_SHADER, vertexShader))
        GLES20.glAttachShader(program, compile(GLES20.GL_FRAGMENT_SHADER, fragmentShader))
        GLES20.glLinkProgram(program)
        val status = IntArray(1)
        GLES20.glGetProgramiv(program, GLES20.GL_LINK_STATUS, status, 0)
        check(status[0] == GLES20.GL_TRUE) { "GL link failed: ${GLES20.glGetProgramInfoLog(program)}" }
        return program
    }

    private fun compile(type: Int, source: String): Int {
        val shader = GLES20.glCreateShader(type)
        GLES20.glShaderSource(shader, source.trimIndent())
        GLES20.glCompileShader(shader)
        val status = IntArray(1)
        GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, status, 0)
        check(status[0] == GLES20.GL_TRUE) { "GL compile failed: ${GLES20.glGetShaderInfoLog(shader)}" }
        return shader
    }
}
