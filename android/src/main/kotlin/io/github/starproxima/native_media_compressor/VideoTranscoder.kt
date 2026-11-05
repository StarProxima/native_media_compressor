package io.github.starproxima.native_media_compressor

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.os.Build
import java.io.File
import java.nio.ByteBuffer
import kotlin.math.min

/**
 * Re-encodes a video to H.264: the decoder renders each frame onto an EGL surface,
 * which scales it onto the encoder's input surface. AAC tracks are copied as is.
 */
internal class VideoTranscoder(
    private val source: MediaSource,
    private val request: VideoRequest,
    private val isCancelled: () -> Boolean,
    private val onProgress: (Double) -> Unit,
) {
    private class Stop(val status: CompressionStatus, message: String? = null) : Exception(message)

    private val maxBytes = request.maxBytes?.takeIf { it > 0 } ?: Long.MAX_VALUE

    fun run(): CompressionReply {
        val destination = File(request.destination)
        destination.delete()
        var reply = CompressionReply(CompressionStatus.FAILED)
        try {
            val size = transcode(destination)
            reply = CompressionReply(
                CompressionStatus.COMPRESSED,
                width = size.width.toLong(),
                height = size.height.toLong(),
                sizeBytes = destination.length(),
            )
        } catch (stop: Stop) {
            reply = CompressionReply(stop.status, message = stop.message)
        } catch (error: MediaCodec.CodecException) {
            reply = CompressionReply(if (isReclaimed(error)) CompressionStatus.INTERRUPTED else CompressionStatus.FAILED, message = error.toString())
        } catch (error: Exception) {
            reply = CompressionReply(CompressionStatus.FAILED, message = error.toString())
        } finally {
            if (reply.status != CompressionStatus.COMPRESSED) destination.delete()
        }
        return reply
    }

    /** Returns the displayed size of the output. */
    private fun transcode(destination: File): Size {
        if (isCancelled()) throw Stop(CompressionStatus.CANCELLED)
        val extractors = mutableListOf<MediaExtractor>()
        var decoder: MediaCodec? = null
        var encoder: MediaCodec? = null
        var inputSurface: InputSurface? = null
        var outputSurface: OutputSurface? = null
        var muxer: MediaMuxer? = null
        try {
            val videoExtractor = source.openExtractor().also(extractors::add)
            val videoTrack = videoExtractor.tracks("video/").firstOrNull()
                ?: throw Stop(CompressionStatus.UNSUPPORTED, "no video track")
            val sourceFormat = videoExtractor.getTrackFormat(videoTrack)
            if (isHdr(sourceFormat)) throw Stop(CompressionStatus.UNSUPPORTED, "HDR video")
            val audioTracks = if (request.includeAudio) videoExtractor.tracks("audio/") else emptyList()
            val audioFormats = audioTracks.map(videoExtractor::getTrackFormat)
            audioFormats.firstOrNull { it.mime != MediaFormat.MIMETYPE_AUDIO_AAC }?.let {
                throw Stop(CompressionStatus.UNSUPPORTED, "audio ${it.mime} cannot be copied without re-encoding")
            }
            videoExtractor.selectTrack(videoTrack)

            val stored = Size(sourceFormat.getInteger(MediaFormat.KEY_WIDTH), sourceFormat.getInteger(MediaFormat.KEY_HEIGHT))
            val rotation = VideoProber.rotation(source, sourceFormat)
            val durationUs = sourceFormat.longOrNull(MediaFormat.KEY_DURATION) ?: 0L
            val sourceFrameRate = sourceFormat.intOrNull(MediaFormat.KEY_FRAME_RATE)?.takeIf { it > 0 }
            val maxFrameRate = request.maxFrameRate?.toInt()?.takeIf { it > 0 }
            val frameRate = listOfNotNull(sourceFrameRate, maxFrameRate).minOrNull() ?: DEFAULT_FRAME_RATE
            val out = Scaling.videoSize(stored, request.maxShortSide, request.maxLongSide)

            val encoderFormat = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, out.width, out.height).apply {
                setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
                setInteger(MediaFormat.KEY_BIT_RATE, request.videoBitrate.coerceIn(1, Int.MAX_VALUE.toLong()).toInt())
                setInteger(MediaFormat.KEY_FRAME_RATE, frameRate)
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2)
            }
            encoder = codec("H.264 encoder") { MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC) }
            codec("H.264 encoder for ${out.width}x${out.height}") {
                encoder.configure(encoderFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            }
            inputSurface = InputSurface(encoder.createInputSurface())
            inputSurface.makeCurrent()
            encoder.start()
            outputSurface = OutputSurface(out.width, out.height)

            // The rotation goes to the output metadata: with it set, the decoder would
            // rotate the frame on the surface and swap width and height.
            sourceFormat.setInteger(MediaFormat.KEY_ROTATION, 0)
            val sourceMime = requireNotNull(sourceFormat.mime)
            decoder = codec("$sourceMime decoder") { MediaCodec.createDecoderByType(sourceMime) }
            codec("$sourceMime decoder for ${stored.width}x${stored.height}") {
                decoder.configure(sourceFormat, outputSurface.surface, null, 0)
            }
            decoder.start()

            muxer = MediaMuxer(destination.path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            muxer.setOrientationHint(rotation)
            // A screen recording with a microphone carries system sound and voice as
            // separate tracks: all of them are copied, or the voice would be lost.
            val audio = audioTracks.zip(audioFormats) { track, format ->
                val extractor = source.openExtractor().also(extractors::add)
                extractor.selectTrack(track)
                AudioCopy(extractor, muxer.addTrack(format), format.intOrNull(MediaFormat.KEY_MAX_INPUT_SIZE))
            }

            Pipeline(
                videoExtractor, decoder, encoder, inputSurface, outputSurface, muxer, audio,
                minFrameIntervalUs = maxFrameRate?.let { 1_000_000L / it } ?: 0L,
                durationUs = durationUs,
                destination = destination,
            ).run()
            muxer.stop()
            if (destination.length() > maxBytes) throw Stop(CompressionStatus.TOO_LARGE)
            return if (rotation % 180 != 0) out.transposed() else out
        } finally {
            runCatching { decoder?.stop() }
            runCatching { decoder?.release() }
            runCatching { encoder?.stop() }
            runCatching { encoder?.release() }
            runCatching { outputSurface?.release() }
            runCatching { inputSurface?.release() }
            runCatching { muxer?.release() }
            extractors.forEach { runCatching { it.release() } }
        }
    }

    private inner class Pipeline(
        private val extractor: MediaExtractor,
        private val decoder: MediaCodec,
        private val encoder: MediaCodec,
        private val inputSurface: InputSurface,
        private val outputSurface: OutputSurface,
        private val muxer: MediaMuxer,
        private val audio: List<AudioCopy>,
        private val minFrameIntervalUs: Long,
        private val durationUs: Long,
        private val destination: File,
    ) {
        private val info = MediaCodec.BufferInfo()
        private var isInputDone = false
        private var isDecoderDone = false
        private var isEncoderDone = false
        private var muxerVideoTrack = -1
        private var lastRenderedUs = Long.MIN_VALUE
        private var lastWrittenUs = 0L
        private var writtenSamples = 0
        private var reportedPercent = -1

        fun run() {
            while (!isEncoderDone) {
                if (isCancelled()) throw Stop(CompressionStatus.CANCELLED)
                if (!isInputDone) feedDecoder()
                if (!isDecoderDone) renderDecoded()
                drainEncoder()
                if (muxerVideoTrack >= 0) audio.forEach { it.copyUpTo(muxer, lastWrittenUs, ::onSampleWritten) }
            }
            audio.forEach { it.copyUpTo(muxer, Long.MAX_VALUE, ::onSampleWritten) }
        }

        private fun feedDecoder() {
            val index = decoder.dequeueInputBuffer(TIMEOUT_US)
            if (index < 0) return
            val buffer = requireNotNull(decoder.getInputBuffer(index))
            val size = extractor.readSampleData(buffer, 0)
            if (size < 0) {
                decoder.queueInputBuffer(index, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                isInputDone = true
            } else {
                decoder.queueInputBuffer(index, 0, size, extractor.sampleTime, 0)
                extractor.advance()
            }
        }

        private fun renderDecoded() {
            val index = decoder.dequeueOutputBuffer(info, TIMEOUT_US)
            // Container metadata does not always tell HDR apart, but the decoder
            // reports the real color transfer before the first frame.
            if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED && isHdr(decoder.outputFormat)) {
                throw Stop(CompressionStatus.UNSUPPORTED, "HDR video")
            }
            if (index < 0) return
            val time = info.presentationTimeUs
            // Frames closer than the frame rate cap are dropped before the encoder.
            val shouldRender = info.size > 0 &&
                (lastRenderedUs == Long.MIN_VALUE || time - lastRenderedUs >= minFrameIntervalUs - FRAME_TOLERANCE_US)
            decoder.releaseOutputBuffer(index, shouldRender)
            if (shouldRender) {
                outputSurface.awaitNewImage()
                outputSurface.drawImage()
                inputSurface.setPresentationTime(time * 1000)
                inputSurface.swapBuffers()
                lastRenderedUs = time
            }
            if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                encoder.signalEndOfInputStream()
                isDecoderDone = true
            }
        }

        private fun drainEncoder() {
            while (true) {
                val index = encoder.dequeueOutputBuffer(info, if (isDecoderDone) TIMEOUT_US else 0)
                when {
                    index == MediaCodec.INFO_TRY_AGAIN_LATER -> return
                    index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        muxerVideoTrack = muxer.addTrack(encoder.outputFormat)
                        muxer.start()
                    }
                    index >= 0 -> {
                        val buffer = requireNotNull(encoder.getOutputBuffer(index))
                        if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) info.size = 0
                        if (info.size > 0 && muxerVideoTrack >= 0) {
                            muxer.writeSampleData(muxerVideoTrack, buffer, info)
                            lastWrittenUs = maxOf(lastWrittenUs, info.presentationTimeUs)
                            onSampleWritten()
                            reportProgress()
                        }
                        encoder.releaseOutputBuffer(index, false)
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                            isEncoderDone = true
                            return
                        }
                    }
                }
            }
        }

        private fun onSampleWritten() {
            writtenSamples++
            if (writtenSamples % SIZE_CHECK_SAMPLES != 0) return
            if (isCancelled()) throw Stop(CompressionStatus.CANCELLED)
            if (destination.length() > maxBytes) throw Stop(CompressionStatus.TOO_LARGE)
        }

        private fun reportProgress() {
            if (durationUs <= 0) return
            val percent = (lastWrittenUs * 100 / durationUs).toInt().coerceIn(0, 99)
            if (percent <= reportedPercent) return
            reportedPercent = percent
            onProgress(percent / 100.0)
        }
    }

    private class AudioCopy(
        private val extractor: MediaExtractor,
        private val track: Int,
        maxInputSize: Int?,
    ) {
        private val buffer = ByteBuffer.allocateDirect(maxInputSize?.takeIf { it > 0 } ?: DEFAULT_AUDIO_BUFFER)
        private val info = MediaCodec.BufferInfo()
        private var isDone = false

        /** Writes audio up to [untilUs], so it is interleaved with the video in the file. */
        fun copyUpTo(muxer: MediaMuxer, untilUs: Long, onWritten: () -> Unit) {
            while (!isDone) {
                val time = extractor.sampleTime
                if (time > untilUs) return
                val size = extractor.readSampleData(buffer, 0)
                if (size < 0) {
                    isDone = true
                    return
                }
                // AAC often starts with a few samples of negative time (encoder delay),
                // which the muxer rejects. They are skipped, not taken for the end of
                // the track.
                if (time < 0) {
                    extractor.advance()
                    continue
                }
                val isSync = extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0
                info.set(0, size, time, if (isSync) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0)
                muxer.writeSampleData(track, buffer, info)
                extractor.advance()
                onWritten()
            }
        }
    }

    private companion object {
        const val TIMEOUT_US = 10_000L
        const val FRAME_TOLERANCE_US = 2_000L
        const val SIZE_CHECK_SAMPLES = 30
        const val DEFAULT_AUDIO_BUFFER = 256 * 1024
        const val DEFAULT_FRAME_RATE = 30

        // A missing codec or one that rejects this format is a platform limit, not a broken input.
        private inline fun <T> codec(what: String, block: () -> T): T = try {
            block()
        } catch (error: Exception) {
            throw Stop(CompressionStatus.UNSUPPORTED, "no $what: $error")
        }

        fun isHdr(format: MediaFormat): Boolean = when (format.intOrNull(MediaFormat.KEY_COLOR_TRANSFER)) {
            MediaFormat.COLOR_TRANSFER_ST2084, MediaFormat.COLOR_TRANSFER_HLG -> true
            else -> false
        }

        // The media server takes codecs back from apps in the background.
        fun isReclaimed(error: MediaCodec.CodecException): Boolean =
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && error.errorCode == MediaCodec.CodecException.ERROR_RECLAIMED
    }
}
