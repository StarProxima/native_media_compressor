package io.github.starproxima.native_media_compressor

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.ThreadFactory
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/** Compresses images and videos with the system codecs. */
class NativeMediaCompressorPlugin : FlutterPlugin, MediaCompressorHostApi {
    private lateinit var context: Context
    private var flutterApi: MediaCompressorFlutterApi? = null
    private val main = Handler(Looper.getMainLooper())

    // Two videos at once would share the hardware encoder and both take twice
    // as long, so they run one after another.
    private var videoExecutor: ExecutorService? = null

    // Full-size decodes are memory-heavy, so only a couple run at once.
    private var imageExecutor: ExecutorService? = null
    private var probeExecutor: ExecutorService? = null
    private val videoTasks = ConcurrentHashMap<Long, AtomicBoolean>()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        videoExecutor = Executors.newSingleThreadExecutor(threads("video"))
        imageExecutor = Executors.newFixedThreadPool(IMAGE_THREADS, threads("image"))
        probeExecutor = Executors.newCachedThreadPool(threads("probe"))
        flutterApi = MediaCompressorFlutterApi(binding.binaryMessenger)
        MediaCompressorHostApi.setUp(binding.binaryMessenger, this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        MediaCompressorHostApi.setUp(binding.binaryMessenger, null)
        flutterApi = null
        videoTasks.values.forEach { it.set(true) }
        listOfNotNull(videoExecutor, imageExecutor, probeExecutor).forEach { it.shutdown() }
        videoExecutor = null
        imageExecutor = null
        probeExecutor = null
    }

    override fun compressVideo(taskId: Long, request: VideoRequest, callback: (Result<CompressionReply>) -> Unit) {
        // After a hot restart a new isolate can reuse the id of a task that still
        // runs here, so the cancel flag also serves as the task's identity: an old
        // task neither reports progress under the id nor unregisters the new one.
        val cancelled = AtomicBoolean(false)
        videoTasks[taskId] = cancelled
        requireNotNull(videoExecutor).execute {
            val reply = guard {
                VideoTranscoder(
                    source = MediaSource(context, request.source),
                    request = request,
                    isCancelled = cancelled::get,
                    onProgress = { progress ->
                        main.post { if (videoTasks[taskId] === cancelled) sendProgress(taskId, progress) }
                    },
                ).run()
            }
            val ownsId = videoTasks.remove(taskId, cancelled)
            main.post {
                if (ownsId && reply.status == CompressionStatus.COMPRESSED) sendProgress(taskId, 1.0)
                callback(Result.success(reply))
            }
        }
    }

    override fun compressImage(request: ImageRequest, callback: (Result<CompressionReply>) -> Unit) {
        requireNotNull(imageExecutor).execute {
            val reply = guard { ImageCompressor(MediaSource(context, request.source), request).run() }
            main.post { callback(Result.success(reply)) }
        }
    }

    override fun videoThumbnail(request: ThumbnailRequest, callback: (Result<CompressionReply>) -> Unit) {
        requireNotNull(imageExecutor).execute {
            val reply = guard { VideoThumbnailer(MediaSource(context, request.source), request).run() }
            main.post { callback(Result.success(reply)) }
        }
    }

    override fun cancel(taskId: Long) {
        videoTasks[taskId]?.set(true)
    }

    override fun probeImage(source: String, callback: (Result<ImageProbe?>) -> Unit) {
        requireNotNull(probeExecutor).execute {
            val probe = runCatching { ImageProber.probe(MediaSource(context, source)) }.getOrNull()
            main.post { callback(Result.success(probe)) }
        }
    }

    override fun probeVideo(source: String, callback: (Result<VideoProbe?>) -> Unit) {
        requireNotNull(probeExecutor).execute {
            val probe = runCatching { VideoProber.probe(MediaSource(context, source)) }.getOrNull()
            main.post { callback(Result.success(probe)) }
        }
    }

    private fun sendProgress(taskId: Long, progress: Double) {
        flutterApi?.onProgress(taskId, progress) {}
    }

    private companion object {
        const val IMAGE_THREADS = 2

        inline fun guard(block: () -> CompressionReply): CompressionReply = try {
            block()
        } catch (error: Throwable) {
            CompressionReply(CompressionStatus.FAILED, message = error.toString())
        }

        fun threads(kind: String): ThreadFactory {
            val count = AtomicInteger()
            return ThreadFactory { runnable ->
                Thread(runnable, "native-media-compressor-$kind-${count.incrementAndGet()}")
            }
        }
    }
}
