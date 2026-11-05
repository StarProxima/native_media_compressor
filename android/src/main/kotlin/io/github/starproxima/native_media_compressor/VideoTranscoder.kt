package io.github.starproxima.native_media_compressor

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecInfo.CodecProfileLevel
import android.media.MediaCodecList
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.os.Build
import java.io.File
import java.io.IOException
import java.nio.ByteBuffer

/**
 * Re-encodes a video to H.264: decoded frames are drawn onto the encoder's input
 * surface through EGL, which scales them and, for HDR input, tone-maps them to SDR.
 * AAC tracks are copied as is.
 */
internal class VideoTranscoder(
    private val source: MediaSource,
    private val request: VideoRequest,
    private val isCancelled: () -> Boolean,
    private val onProgress: (Double) -> Unit,
) {
    private class Stop(val status: CompressionStatus, message: String? = null) : Exception(message)

    /** The decoder cannot hand over SDR frames on a surface; start again with [ToneMappedFrames]. */
    private class ToneMapInShader(val transfer: HdrTransfer) : Exception()

    private val maxBytes = request.maxBytes?.takeIf { it > 0 } ?: Long.MAX_VALUE

    fun run(): CompressionReply {
        if (isCancelled()) return CompressionReply(CompressionStatus.CANCELLED)
        val output = try {
            StagedOutput.create(request.destination)
        } catch (error: IOException) {
            return CompressionReply(CompressionStatus.FAILED, message = error.toString())
        }
        var reply = CompressionReply(CompressionStatus.FAILED)
        try {
            val size = try {
                transcode(output.file, shaderTransfer = null)
            } catch (restart: ToneMapInShader) {
                transcode(output.file, restart.transfer)
            }
            reply = CompressionReply(
                CompressionStatus.COMPRESSED,
                width = size.width.toLong(),
                height = size.height.toLong(),
                sizeBytes = output.file.length(),
            )
        } catch (stop: Stop) {
            reply = CompressionReply(stop.status, message = stop.message)
        } catch (error: MediaCodec.CodecException) {
            reply = CompressionReply(if (isReclaimed(error)) CompressionStatus.INTERRUPTED else CompressionStatus.FAILED, message = error.toString())
        } catch (error: Exception) {
            reply = CompressionReply(CompressionStatus.FAILED, message = error.toString())
        } finally {
            if (reply.status != CompressionStatus.COMPRESSED) output.discard()
        }
        return output.finish(reply)
    }

    /**
     * Returns the displayed size of the output. With [shaderTransfer] set, frames are
     * decoded into buffers and tone-mapped from that transfer function in the shader.
     */
    private fun transcode(destination: File, shaderTransfer: HdrTransfer?): Size {
        if (isCancelled()) throw Stop(CompressionStatus.CANCELLED)
        val extractors = mutableListOf<MediaExtractor>()
        var decoder: MediaCodec? = null
        var encoder: MediaCodec? = null
        var inputSurface: InputSurface? = null
        var frames: DecodedFrames? = null
        var muxer: MediaMuxer? = null
        try {
            val videoExtractor = source.openExtractor().also(extractors::add)
            val videoTrack = videoExtractor.tracks("video/").firstOrNull()
                ?: throw Stop(CompressionStatus.UNSUPPORTED, "no video track")
            val sourceFormat = videoExtractor.getTrackFormat(videoTrack)
            val transfer = shaderTransfer ?: VideoProber.hdrTransfer(source, sourceFormat)
            if (transfer.isHdr && Build.VERSION.SDK_INT < Build.VERSION_CODES.N) {
                throw Stop(CompressionStatus.UNSUPPORTED, "HDR video needs API 24")
            }
            // HDR streams are mostly 10-bit, which many decoders lack (the profile tells).
            if (transfer.isHdr && MediaCodecList(MediaCodecList.REGULAR_CODECS).findDecoderForFormat(sourceFormat) == null) {
                throw Stop(CompressionStatus.UNSUPPORTED, "no decoder for this HDR stream: $sourceFormat")
            }
            // Decoders tone-map on request only from API 31; the shader does it otherwise.
            val toneMapInShader = transfer.isHdr && (shaderTransfer != null || Build.VERSION.SDK_INT < Build.VERSION_CODES.S)
            // Only audio tracks matter: screen recordings also carry data tracks without a codec.
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
            // Variable frame rate recordings report the timescale as their rate, such
            // as 19200 fps, which the encoder's rate control must not see.
            val frameRate = (listOfNotNull(sourceFrameRate, maxFrameRate).minOrNull() ?: DEFAULT_FRAME_RATE)
                .coerceAtMost(MAX_ENCODER_FRAME_RATE)
            encoder = codec("H.264 encoder") { MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC) }
            val out = outputSize(stored, videoCapabilities(encoder))

            val encoderFormat = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, out.width, out.height).apply {
                setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
                setInteger(MediaFormat.KEY_BIT_RATE, request.videoBitrate.coerceIn(1, Int.MAX_VALUE.toLong()).toInt())
                setInteger(MediaFormat.KEY_FRAME_RATE, frameRate)
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    setInteger(MediaFormat.KEY_COLOR_STANDARD, MediaFormat.COLOR_STANDARD_BT709)
                    setInteger(MediaFormat.KEY_COLOR_TRANSFER, MediaFormat.COLOR_TRANSFER_SDR_VIDEO)
                    setInteger(MediaFormat.KEY_COLOR_RANGE, MediaFormat.COLOR_RANGE_LIMITED)
                }
            }
            codec("H.264 encoder for ${out.width}x${out.height}") {
                encoder.configure(encoderFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            }
            inputSurface = InputSurface(encoder.createInputSurface())
            inputSurface.makeCurrent()
            encoder.start()

            // The rotation goes to the output metadata: with it set, the decoder would
            // rotate the frame on the surface and swap width and height.
            sourceFormat.setInteger(MediaFormat.KEY_ROTATION, 0)
            val surfaceFrames = if (toneMapInShader) {
                // Without an explicit P010 request some decoders cut 10-bit output to 8 bits,
                // while 8-bit decoders reject P010.
                sourceFormat.setInteger(
                    MediaFormat.KEY_COLOR_FORMAT,
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && isTenBit(sourceFormat)) {
                        MediaCodecInfo.CodecCapabilities.COLOR_FormatYUVP010
                    } else {
                        MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible
                    },
                )
                frames = BufferFrames(ToneMappedFrames(out.width, out.height, transfer))
                null
            } else {
                if (transfer.isHdr) {
                    sourceFormat.setInteger(MediaFormat.KEY_COLOR_TRANSFER_REQUEST, MediaFormat.COLOR_TRANSFER_SDR_VIDEO)
                }
                SurfaceFrames(OutputSurface(out.width, out.height), transfer).also { frames = it }
            }
            val sourceMime = requireNotNull(sourceFormat.mime)
            decoder = codec("$sourceMime decoder") { MediaCodec.createDecoderByType(sourceMime) }
            codec("$sourceMime decoder for ${stored.width}x${stored.height}") {
                decoder.configure(sourceFormat, surfaceFrames?.surface, null, 0)
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

            val pipeline = Pipeline(
                videoExtractor, decoder, encoder, inputSurface, requireNotNull(frames), muxer, audio,
                maxFrameRate = maxFrameRate,
                durationUs = durationUs,
                destination = destination,
            )
            try {
                pipeline.run()
            } catch (error: Exception) {
                // Some decoders accept 10-bit input but fail as soon as they have to
                // put a 10-bit frame on a surface.
                if (transfer.isHdr && !pipeline.hasRendered && error !is Stop && error !is ToneMapInShader) {
                    if (!toneMapInShader) throw ToneMapInShader(transfer)
                    throw Stop(CompressionStatus.UNSUPPORTED, "the decoder cannot decode this HDR stream: $error")
                }
                throw error
            }
            muxer.stop()
            if (destination.length() > maxBytes) throw Stop(CompressionStatus.TOO_LARGE)
            return if (rotation % 180 != 0) out.transposed() else out
        } finally {
            runCatching { decoder?.stop() }
            runCatching { decoder?.release() }
            runCatching { encoder?.stop() }
            runCatching { encoder?.release() }
            runCatching { frames?.release() }
            runCatching { inputSurface?.release() }
            runCatching { muxer?.release() }
            extractors.forEach { runCatching { it.release() } }
        }
    }

    /**
     * Stored size of the output, aligned to what [capabilities] require (usually
     * even sides). Encoders that reject that size get multiples of 16, which every
     * H.264 encoder takes.
     */
    private fun outputSize(stored: Size, capabilities: MediaCodecInfo.VideoCapabilities?): Size {
        val aligned = Scaling.videoSize(
            stored, request.maxShortSide, request.maxLongSide,
            widthAlignment = capabilities?.widthAlignment ?: 2,
            heightAlignment = capabilities?.heightAlignment ?: 2,
        )
        if (capabilities == null || capabilities.isSizeSupported(aligned.width, aligned.height)) return aligned
        return Scaling.videoSize(stored, request.maxShortSide, request.maxLongSide, widthAlignment = 16, heightAlignment = 16)
    }

    private interface DecodedFrames {
        fun onOutputFormat(format: MediaFormat)

        /** Draws output buffer [index] when [draw] is set and returns the buffer to the decoder either way. */
        fun render(decoder: MediaCodec, index: Int, draw: Boolean)

        fun release()
    }

    private class SurfaceFrames(private val output: OutputSurface, private val sourceTransfer: HdrTransfer) : DecodedFrames {
        val surface get() = output.surface

        // The decoder reports the transfer it really outputs before the first frame:
        // HDR frames on a surface cannot be tone-mapped, whatever the container said.
        override fun onOutputFormat(format: MediaFormat) {
            val reported = format.intOrNull(MediaFormat.KEY_COLOR_TRANSFER)
            val isSdr = reported == MediaFormat.COLOR_TRANSFER_SDR_VIDEO
            if (sourceTransfer.isHdr && !isSdr) throw ToneMapInShader(sourceTransfer)
            if (HdrTransfer.of(reported).isHdr) throw ToneMapInShader(HdrTransfer.of(reported))
        }

        override fun render(decoder: MediaCodec, index: Int, draw: Boolean) {
            decoder.releaseOutputBuffer(index, draw)
            if (draw) {
                output.awaitNewImage()
                output.drawImage()
            }
        }

        override fun release() = output.release()
    }

    private class BufferFrames(private val toneMapped: ToneMappedFrames) : DecodedFrames {
        override fun onOutputFormat(format: MediaFormat) = toneMapped.onOutputFormat(format)

        override fun render(decoder: MediaCodec, index: Int, draw: Boolean) {
            try {
                if (draw) {
                    val image = decoder.getOutputImage(index) ?: error("decoder gave no image")
                    image.use(toneMapped::draw)
                }
            } finally {
                decoder.releaseOutputBuffer(index, false)
            }
        }

        override fun release() = toneMapped.release()
    }

    private inner class Pipeline(
        private val extractor: MediaExtractor,
        private val decoder: MediaCodec,
        private val encoder: MediaCodec,
        private val inputSurface: InputSurface,
        private val frames: DecodedFrames,
        private val muxer: MediaMuxer,
        private val audio: List<AudioCopy>,
        maxFrameRate: Int?,
        private val durationUs: Long,
        private val destination: File,
    ) {
        private val info = MediaCodec.BufferInfo()
        private var isInputDone = false
        private var isDecoderDone = false
        private var isEncoderDone = false
        private var muxerVideoTrack = -1
        private val frameSelector = FrameSelector(maxFrameRate)
        private var lastWrittenUs = 0L
        private var writtenSamples = 0
        private var reportedPercent = -1

        var hasRendered = false
            private set

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
            if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) frames.onOutputFormat(decoder.outputFormat)
            if (index < 0) return
            val time = info.presentationTimeUs
            val shouldRender = info.size > 0 && frameSelector.accept(time)
            frames.render(decoder, index, shouldRender)
            if (shouldRender) {
                inputSurface.setPresentationTime(time * 1000)
                inputSurface.swapBuffers()
                hasRendered = true
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
        const val SIZE_CHECK_SAMPLES = 30
        const val DEFAULT_AUDIO_BUFFER = 256 * 1024
        const val DEFAULT_FRAME_RATE = 30
        const val MAX_ENCODER_FRAME_RATE = 240

        // A missing codec or one that rejects this format is a platform limit, not a broken input.
        private inline fun <T> codec(what: String, block: () -> T): T = try {
            block()
        } catch (error: Exception) {
            throw Stop(CompressionStatus.UNSUPPORTED, "no $what: $error")
        }

        fun videoCapabilities(codec: MediaCodec): MediaCodecInfo.VideoCapabilities? = runCatching {
            val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                codec.codecInfo
            } else {
                MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos.first { it.name == codec.name }
            }
            info.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_AVC).videoCapabilities
        }.getOrNull()

        /** Whether the stream's profile carries 10-bit samples; HDR without a known profile is assumed to. */
        fun isTenBit(format: MediaFormat): Boolean {
            val profile = format.intOrNull(MediaFormat.KEY_PROFILE) ?: return true
            return when (format.mime) {
                MediaFormat.MIMETYPE_VIDEO_AVC -> profile == CodecProfileLevel.AVCProfileHigh10
                MediaFormat.MIMETYPE_VIDEO_HEVC -> profile in setOf(
                    CodecProfileLevel.HEVCProfileMain10,
                    CodecProfileLevel.HEVCProfileMain10HDR10,
                    CodecProfileLevel.HEVCProfileMain10HDR10Plus,
                )
                MediaFormat.MIMETYPE_VIDEO_VP9 -> profile in setOf(
                    CodecProfileLevel.VP9Profile2,
                    CodecProfileLevel.VP9Profile3,
                    CodecProfileLevel.VP9Profile2HDR,
                    CodecProfileLevel.VP9Profile3HDR,
                    CodecProfileLevel.VP9Profile2HDR10Plus,
                    CodecProfileLevel.VP9Profile3HDR10Plus,
                )
                MediaFormat.MIMETYPE_VIDEO_AV1 -> profile in setOf(
                    CodecProfileLevel.AV1ProfileMain10,
                    CodecProfileLevel.AV1ProfileMain10HDR10,
                    CodecProfileLevel.AV1ProfileMain10HDR10Plus,
                )
                else -> true
            }
        }

        // The media server takes codecs back from apps in the background.
        fun isReclaimed(error: MediaCodec.CodecException): Boolean =
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && error.errorCode == MediaCodec.CodecException.ERROR_RECLAIMED
    }
}
