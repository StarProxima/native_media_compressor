package io.github.starproxima.native_media_compressor

import android.media.AudioFormat
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
 * Re-encodes a video to H.264 or HEVC: decoded frames are drawn onto the encoder's
 * input surface through EGL, which scales them and, for HDR input, tone-maps them
 * to SDR. AAC tracks are copied as is, other audio is re-encoded to AAC.
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

    private class Transcoded(val size: Size, val mime: String)

    private val maxBytes = request.maxBytes?.takeIf { it > 0 } ?: Long.MAX_VALUE
    private val range = TimeRange.of(request.startMs, request.endMs)

    fun run(): CompressionReply {
        if (isCancelled()) return CompressionReply(CompressionStatus.CANCELLED)
        val output = try {
            StagedOutput.create(request.destination)
        } catch (error: IOException) {
            return CompressionReply(CompressionStatus.FAILED, message = error.toString())
        }
        var reply = CompressionReply(CompressionStatus.FAILED)
        try {
            val transcoded = try {
                transcode(output.file, shaderTransfer = null)
            } catch (restart: ToneMapInShader) {
                transcode(output.file, restart.transfer)
            }
            reply = CompressionReply(
                CompressionStatus.COMPRESSED,
                width = transcoded.size.width.toLong(),
                height = transcoded.size.height.toLong(),
                sizeBytes = output.file.length(),
                videoCodec = transcoded.mime,
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
     * Returns the displayed size and codec of the output. With [shaderTransfer] set, frames
     * are decoded into buffers and tone-mapped from that transfer function in the shader.
     */
    private fun transcode(destination: File, shaderTransfer: HdrTransfer?): Transcoded {
        if (isCancelled()) throw Stop(CompressionStatus.CANCELLED)
        val extractors = mutableListOf<MediaExtractor>()
        var decoder: MediaCodec? = null
        var encoder: MediaCodec? = null
        var inputSurface: InputSurface? = null
        var frames: DecodedFrames? = null
        var muxer: MediaMuxer? = null
        val audio = mutableListOf<AudioWriter>()
        try {
            val videoExtractor = source.openExtractor().also(extractors::add)
            val videoTrack = videoExtractor.tracks("video/").firstOrNull()
                ?: throw Stop(CompressionStatus.UNSUPPORTED, "no video track")
            val trackFormat = videoExtractor.getTrackFormat(videoTrack)
            val (sourceFormat, decoderName) = findDecoder(trackFormat)
            val transfer = shaderTransfer ?: VideoProber.hdrTransfer(source, trackFormat).let {
                // Dolby Vision is PQ-based when the track does not name a transfer;
                // an explicit SDR transfer (profile 8.2) stays SDR.
                val unnamed = !trackFormat.containsKey(MediaFormat.KEY_COLOR_TRANSFER)
                if (!it.isHdr && unnamed && trackFormat.mime == MediaFormat.MIMETYPE_VIDEO_DOLBY_VISION) {
                    HdrTransfer.PQ
                } else {
                    it
                }
            }
            if (transfer.isHdr && Build.VERSION.SDK_INT < Build.VERSION_CODES.N) {
                throw Stop(CompressionStatus.UNSUPPORTED, "HDR video needs API 24")
            }
            // HDR streams are mostly 10-bit, which many decoders lack (the profile tells).
            if (transfer.isHdr && decoderName == null) {
                throw Stop(CompressionStatus.UNSUPPORTED, "no decoder for this HDR stream: $trackFormat")
            }
            // Decoders tone-map on request only from API 31; the shader does it otherwise.
            val toneMapInShader = transfer.isHdr && (shaderTransfer != null || Build.VERSION.SDK_INT < Build.VERSION_CODES.S)
            // Only audio tracks matter: screen recordings also carry data tracks without a codec.
            val audioTracks = if (request.includeAudio) videoExtractor.tracks("audio/") else emptyList()
            val audioFormats = audioTracks.map(videoExtractor::getTrackFormat)
            videoExtractor.selectTrack(videoTrack)

            val stored = Size(sourceFormat.getInteger(MediaFormat.KEY_WIDTH), sourceFormat.getInteger(MediaFormat.KEY_HEIGHT))
            val rotation = VideoProber.rotation(source, sourceFormat)
            val durationUs = sourceFormat.longOrNull(MediaFormat.KEY_DURATION) ?: 0L
            if (range.keepsNothing(durationUs)) {
                throw Stop(CompressionStatus.UNSUPPORTED, "the range ${request.startMs}..${request.endMs} ms keeps nothing")
            }
            val sourceFrameRate = sourceFormat.intOrNull(MediaFormat.KEY_FRAME_RATE)?.takeIf { it > 0 }
            val maxFrameRate = request.maxFrameRate?.toInt()?.takeIf { it > 0 }
            // Variable frame rate recordings report the timescale as their rate, such
            // as 19200 fps, which the encoder's rate control must not see.
            val frameRate = (listOfNotNull(sourceFrameRate, maxFrameRate).minOrNull() ?: DEFAULT_FRAME_RATE)
                .coerceAtMost(MAX_ENCODER_FRAME_RATE)
            // MediaMuxer writes HEVC into MP4 only from API 24; before that an HEVC
            // encoder may configure fine and the muxer then rejects its first frame.
            val canMuxHevc = Build.VERSION.SDK_INT >= Build.VERSION_CODES.N
            val configured = if (request.codec == VideoCodec.HEVC && canMuxHevc) {
                runCatching { configureEncoder(MediaFormat.MIMETYPE_VIDEO_HEVC, stored, frameRate) }.getOrNull()
            } else {
                null
            } ?: configureEncoder(MediaFormat.MIMETYPE_VIDEO_AVC, stored, frameRate)
            encoder = configured.codec
            val out = configured.size
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
            decoder = codec("$sourceMime decoder") {
                decoderName?.let(MediaCodec::createByCodecName) ?: MediaCodec.createDecoderByType(sourceMime)
            }
            codec("$sourceMime decoder for ${stored.width}x${stored.height}") {
                decoder.configure(sourceFormat, surfaceFrames?.surface, null, 0)
            }
            decoder.start()

            // The turn goes to the orientation hint like the source rotation, so frames
            // are never rotated in pixels.
            val outputRotation = Rotation.add(rotation, request.rotateQuarterTurns)
            muxer = MediaMuxer(destination.path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            muxer.setOrientationHint(outputRotation)
            // A screen recording with a microphone carries system sound and voice as
            // separate tracks: all of them are kept, or the voice would be lost.
            val audioBitrate = request.audioBitrate.coerceIn(1, Int.MAX_VALUE.toLong()).toInt()
            for ((track, format) in audioTracks.zip(audioFormats)) {
                val extractor = source.openExtractor().also(extractors::add)
                extractor.selectTrack(track)
                // Audio samples are all sync samples, so this lands at the start or just before it.
                if (range.startUs > 0) extractor.seekTo(range.startUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
                val writer = if (format.mime == MediaFormat.MIMETYPE_AUDIO_AAC) {
                    AudioCopy(extractor, format, range)
                } else {
                    AudioReencoder(extractor, format, audioBitrate, range)
                }
                audio += writer
                writer.track = muxer.addTrack(writer.prepare())
            }

            if (range.startUs > 0) videoExtractor.seekTo(range.startUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            val pipeline = Pipeline(
                videoExtractor, decoder, encoder, inputSurface, requireNotNull(frames), muxer, audio,
                maxFrameRate = maxFrameRate,
                durationUs = range.keptDurationUs(durationUs),
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
            return Transcoded(out.rotated(outputRotation), configured.mime)
        } finally {
            runCatching { decoder?.stop() }
            runCatching { decoder?.release() }
            runCatching { encoder?.stop() }
            runCatching { encoder?.release() }
            runCatching { frames?.release() }
            runCatching { inputSurface?.release() }
            // release() stops a started muxer first and skips the native release when
            // that stop throws, so a failed stop is taken separately.
            runCatching { muxer?.stop() }
            runCatching { muxer?.release() }
            audio.forEach { runCatching { it.release() } }
            extractors.forEach { runCatching { it.release() } }
        }
    }

    private class ConfiguredEncoder(val codec: MediaCodec, val mime: String, val size: Size)

    /** Creates and configures an encoder for [mime]; throws [Stop] when the device cannot. */
    private fun configureEncoder(mime: String, stored: Size, frameRate: Int): ConfiguredEncoder {
        val name = if (mime == MediaFormat.MIMETYPE_VIDEO_HEVC) "HEVC" else "H.264"
        val encoder = codec("$name encoder") { MediaCodec.createEncoderByType(mime) }
        try {
            val capabilities = codecCapabilities(encoder, mime)
            val out = outputSize(stored, capabilities?.videoCapabilities)
            val requested = request.videoBitrate.coerceIn(1, Int.MAX_VALUE.toLong()).toInt()
            val bitrate = capabilities?.videoCapabilities?.bitrateRange?.clamp(requested) ?: requested
            val format = MediaFormat.createVideoFormat(mime, out.width, out.height).apply {
                setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
                setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
                setInteger(MediaFormat.KEY_FRAME_RATE, frameRate)
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    setInteger(MediaFormat.KEY_COLOR_STANDARD, MediaFormat.COLOR_STANDARD_BT709)
                    setInteger(MediaFormat.KEY_COLOR_TRANSFER, MediaFormat.COLOR_TRANSFER_SDR_VIDEO)
                    setInteger(MediaFormat.KEY_COLOR_RANGE, MediaFormat.COLOR_RANGE_LIMITED)
                }
                // The software H.264 encoder stops at quantizer 40 by default, which keeps
                // a detailed 1080p frame far above a low bitrate; the full range reaches it.
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    for (key in listOf(
                        MediaFormat.KEY_VIDEO_QP_MAX, MediaFormat.KEY_VIDEO_QP_I_MAX,
                        MediaFormat.KEY_VIDEO_QP_P_MAX, MediaFormat.KEY_VIDEO_QP_B_MAX,
                    )) {
                        setInteger(key, MAX_QP)
                    }
                }
                // Frames from the surface are 8-bit, and Main plays on more devices than
                // Main 10. Encoders reject a profile without a level they support.
                if (mime == MediaFormat.MIMETYPE_VIDEO_HEVC && Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    capabilities?.profileLevels
                        ?.filter { it.profile == CodecProfileLevel.HEVCProfileMain }
                        ?.maxByOrNull { it.level }
                        ?.let {
                            setInteger(MediaFormat.KEY_PROFILE, it.profile)
                            setInteger(MediaFormat.KEY_LEVEL, it.level)
                        }
                }
            }
            var failure: Exception? = null
            var isVbrRaised = false
            for (mode in bitrateModes(capabilities?.encoderCapabilities)) {
                mode?.let { format.setInteger(MediaFormat.KEY_BITRATE_MODE, it) }
                try {
                    encoder.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                } catch (error: Exception) {
                    failure = error
                    encoder.reset()
                    continue
                }
                // From API 31 the platform may lift a VBR bitrate to its own quality
                // floor, several times the request; CBR keeps the bitrate asked for.
                val applied = runCatching { encoder.outputFormat.intOrNull(MediaFormat.KEY_BIT_RATE) }.getOrNull()
                if (mode == VBR && applied != null && applied > bitrate * MAX_BITRATE_RAISE) {
                    isVbrRaised = true
                    encoder.reset()
                    continue
                }
                return ConfiguredEncoder(encoder, mime, out)
            }
            // A raised bitrate still beats no encoder when CBR is not available.
            if (isVbrRaised) {
                format.setInteger(MediaFormat.KEY_BITRATE_MODE, VBR)
                codec("$name encoder for ${out.width}x${out.height}") {
                    encoder.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                }
                return ConfiguredEncoder(encoder, mime, out)
            }
            if (failure is MediaCodec.CodecException && isTemporary(failure)) {
                throw Stop(CompressionStatus.INTERRUPTED, "$name encoder is busy: $failure")
            }
            throw Stop(CompressionStatus.UNSUPPORTED, "no $name encoder for ${out.width}x${out.height}: $failure")
        } catch (error: Exception) {
            runCatching { encoder.release() }
            throw error
        }
    }

    /**
     * Stored size of the output, aligned to what [capabilities] require (usually
     * even sides). Encoders that reject that size get multiples of 16, which every
     * H.264 and HEVC encoder takes.
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
        private val audio: List<AudioWriter>,
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
                if (muxerVideoTrack >= 0) audio.forEach { it.writeUpTo(muxer, lastWrittenUs, ::onSampleWritten) }
            }
            // Without a single frame the encoder never reports a format and the muxer never starts.
            if (muxerVideoTrack < 0 && range.isTrimmed) throw Stop(CompressionStatus.UNSUPPORTED, "the range keeps no frames")
            audio.forEach { it.writeUpTo(muxer, Long.MAX_VALUE, ::onSampleWritten) }
        }

        private fun feedDecoder() {
            val index = decoder.dequeueInputBuffer(TIMEOUT_US)
            if (index < 0) return
            val buffer = requireNotNull(decoder.getInputBuffer(index))
            val size = extractor.readSampleData(buffer, 0)
            // Frames come in decode order: those shown just before the end can follow
            // a frame shown after it, so decoding goes on a little past the end.
            if (size < 0 || extractor.sampleTime > range.endUs.saturatingPlus(REORDER_MARGIN_US)) {
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
            // Decoding starts at the sync frame before the range: earlier frames are only references.
            val shouldRender = info.size > 0 && range.contains(time) && frameSelector.accept(time)
            frames.render(decoder, index, shouldRender)
            if (shouldRender) {
                inputSurface.setPresentationTime(range.toOutput(time) * 1000)
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

    /** One audio track of the output, written interleaved with the video. */
    private abstract class AudioWriter {
        var track = -1

        /** Format of the output track; the muxer needs every track before it starts. */
        abstract fun prepare(): MediaFormat

        /** Writes audio up to [untilUs] of the output, so it is interleaved with the video in the file. */
        abstract fun writeUpTo(muxer: MediaMuxer, untilUs: Long, onWritten: () -> Unit)

        open fun release() {}
    }

    private class AudioCopy(
        private val extractor: MediaExtractor,
        private val format: MediaFormat,
        private val range: TimeRange,
    ) : AudioWriter() {
        private val buffer = ByteBuffer.allocateDirect(
            format.intOrNull(MediaFormat.KEY_MAX_INPUT_SIZE)?.takeIf { it > 0 } ?: DEFAULT_AUDIO_BUFFER,
        )
        private val info = MediaCodec.BufferInfo()
        private var isDone = false

        override fun prepare(): MediaFormat = format

        override fun writeUpTo(muxer: MediaMuxer, untilUs: Long, onWritten: () -> Unit) {
            while (!isDone) {
                val time = extractor.sampleTime
                if (extractor.sampleTrackIndex < 0 || time >= range.endUs) {
                    isDone = true
                    return
                }
                // AAC often starts with a few samples of negative time (encoder delay),
                // which the muxer rejects. They are skipped like samples before the range.
                if (time < range.startUs) {
                    extractor.advance()
                    continue
                }
                if (range.toOutput(time) > untilUs) return
                val size = extractor.readSampleData(buffer, 0)
                if (size < 0) {
                    isDone = true
                    return
                }
                val isSync = extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0
                info.set(0, size, range.toOutput(time), if (isSync) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0)
                muxer.writeSampleData(track, buffer, info)
                extractor.advance()
                onWritten()
            }
        }
    }

    /** Decodes audio an MP4 does not take as is (MP3 and others) and encodes it to AAC-LC. */
    private class AudioReencoder(
        private val extractor: MediaExtractor,
        private val sourceFormat: MediaFormat,
        private val bitrate: Int,
        private val range: TimeRange,
    ) : AudioWriter() {
        private val info = MediaCodec.BufferInfo()
        private var decoder: MediaCodec? = null
        private var encoder: MediaCodec? = null
        private var outputFormat: MediaFormat? = null
        private var sampleRate = 0
        private var channels = 0
        private var pcmEncoding = AudioFormat.ENCODING_PCM_16BIT

        // 16-bit PCM waiting for the encoder; its first frame is at pcmStartUs of the output.
        private var pcm: ByteBuffer = ByteBuffer.allocateDirect(0)
        private var pcmStartUs = 0L
        private var pcmFramesQueued = 0L
        private var isExtractorDone = false
        private var isDecoderDone = false
        private var isEncoderInputDone = false
        private var isDone = false
        private var heldIndex = -1
        private val heldInfo = MediaCodec.BufferInfo()
        private var lastWrittenUs = Long.MIN_VALUE

        override fun prepare(): MediaFormat {
            val mime = requireNotNull(sourceFormat.mime)
            val decoder = codec("$mime decoder") { MediaCodec.createDecoderByType(mime) }
            this.decoder = decoder
            codec("$mime decoder for $sourceFormat") { decoder.configure(sourceFormat, null, null, 0) }
            decoder.start()
            // The encoder reports its format, with the codec config the muxer needs,
            // only once it has PCM to encode; the encoded output stays queued in it.
            while (true) {
                outputFormat?.let { return it }
                val moved = pump()
                val encoder = encoder
                if (encoder == null) {
                    if (!moved) takeDecoded(TIMEOUT_US)
                    continue
                }
                val index = encoder.dequeueOutputBuffer(info, if (moved) 0 else TIMEOUT_US)
                if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    outputFormat = encoder.outputFormat
                } else if (index >= 0) {
                    outputFormat = encoder.outputFormat
                    heldIndex = index
                    heldInfo.set(info.offset, info.size, info.presentationTimeUs, info.flags)
                }
            }
        }

        override fun writeUpTo(muxer: MediaMuxer, untilUs: Long, onWritten: () -> Unit) {
            val encoder = encoder ?: return
            if (heldIndex >= 0) {
                val index = heldIndex
                heldIndex = -1
                write(muxer, encoder, index, heldInfo, onWritten)
            }
            while (!isDone && lastWrittenUs <= untilUs) {
                val moved = pump()
                val index = encoder.dequeueOutputBuffer(info, if (moved) 0 else TIMEOUT_US)
                if (index >= 0) write(muxer, encoder, index, info, onWritten)
            }
        }

        override fun release() {
            for (codec in listOfNotNull(decoder, encoder)) {
                runCatching { codec.stop() }
                runCatching { codec.release() }
            }
        }

        /** Moves audio one step towards the encoder without waiting; false when nothing could move. */
        private fun pump(): Boolean {
            var moved = false
            if (!isExtractorDone) moved = feedDecoder()
            if (!pcm.hasRemaining() && !isDecoderDone) moved = takeDecoded(0) or moved
            if (encoder != null && !isEncoderInputDone) moved = feedEncoder() or moved
            return moved
        }

        private fun feedDecoder(): Boolean {
            val decoder = requireNotNull(decoder)
            val index = decoder.dequeueInputBuffer(0)
            if (index < 0) return false
            val time = extractor.sampleTime
            val size = if (extractor.sampleTrackIndex < 0 || time >= range.endUs) {
                -1
            } else {
                extractor.readSampleData(requireNotNull(decoder.getInputBuffer(index)), 0)
            }
            if (size < 0) {
                decoder.queueInputBuffer(index, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                isExtractorDone = true
            } else {
                decoder.queueInputBuffer(index, 0, size, time, 0)
                extractor.advance()
            }
            return true
        }

        private fun takeDecoded(waitUs: Long): Boolean {
            val decoder = requireNotNull(decoder)
            val index = decoder.dequeueOutputBuffer(info, waitUs)
            if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                onDecodedFormat(decoder.outputFormat)
                return true
            }
            if (index < 0) return false
            try {
                if (encoder == null) onDecodedFormat(decoder.outputFormat)
                val frameBytes = channels * requireNotNull(Pcm16.bytesPerSample(pcmEncoding))
                val kept = range.pcmFrames(info.presentationTimeUs, info.size / frameBytes, sampleRate)
                if (!kept.isEmpty()) {
                    val buffer = requireNotNull(decoder.getOutputBuffer(index))
                    buffer.position(info.offset + kept.first * frameBytes)
                    buffer.limit(info.offset + (kept.last + 1) * frameBytes)
                    pcm = Pcm16.convert(buffer, pcmEncoding, pcm)
                    pcmStartUs = range.toOutput(info.presentationTimeUs + kept.first * 1_000_000L / sampleRate)
                    pcmFramesQueued = 0
                }
            } finally {
                decoder.releaseOutputBuffer(index, false)
            }
            if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) isDecoderDone = true
            return true
        }

        private fun onDecodedFormat(format: MediaFormat) {
            val rate = format.intOrNull(MediaFormat.KEY_SAMPLE_RATE) ?: sourceFormat.intOrNull(MediaFormat.KEY_SAMPLE_RATE)
            val count = format.intOrNull(MediaFormat.KEY_CHANNEL_COUNT) ?: sourceFormat.intOrNull(MediaFormat.KEY_CHANNEL_COUNT)
            if (rate == null || rate <= 0 || count == null || count <= 0) {
                throw Stop(CompressionStatus.FAILED, "decoded audio has no sample rate or channel count: $format")
            }
            val encoding = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                format.intOrNull(MediaFormat.KEY_PCM_ENCODING) ?: AudioFormat.ENCODING_PCM_16BIT
            } else {
                AudioFormat.ENCODING_PCM_16BIT
            }
            if (encoder != null) {
                // The encoder keeps the layout it started with.
                if (rate != sampleRate || count != channels || encoding != pcmEncoding) {
                    throw Stop(CompressionStatus.UNSUPPORTED, "the audio format changes midway: $format")
                }
                return
            }
            if (Pcm16.bytesPerSample(encoding) == null) {
                throw Stop(CompressionStatus.UNSUPPORTED, "decoded audio in PCM encoding $encoding")
            }
            sampleRate = rate
            channels = count
            pcmEncoding = encoding
            val encoderFormat = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, rate, count).apply {
                setInteger(MediaFormat.KEY_AAC_PROFILE, CodecProfileLevel.AACObjectLC)
                setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
            }
            val encoder = codec("AAC encoder") { MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC) }
            this.encoder = encoder
            codec("AAC encoder for $count channels at $rate Hz") {
                encoder.configure(encoderFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            }
            encoder.start()
        }

        private fun feedEncoder(): Boolean {
            val encoder = requireNotNull(encoder)
            if (!pcm.hasRemaining() && !isDecoderDone) return false
            val index = encoder.dequeueInputBuffer(0)
            if (index < 0) return false
            val timeUs = pcmStartUs + pcmFramesQueued * 1_000_000L / sampleRate
            if (!pcm.hasRemaining()) {
                encoder.queueInputBuffer(index, 0, 0, timeUs, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                isEncoderInputDone = true
                return true
            }
            val input = requireNotNull(encoder.getInputBuffer(index))
            input.clear()
            val frameBytes = channels * 2
            val bytes = minOf(pcm.remaining(), input.remaining() / frameBytes * frameBytes)
            input.put(pcm.duplicate().apply { limit(position() + bytes) })
            pcm.position(pcm.position() + bytes)
            encoder.queueInputBuffer(index, 0, bytes, timeUs, 0)
            pcmFramesQueued += bytes / frameBytes
            return true
        }

        private fun write(muxer: MediaMuxer, encoder: MediaCodec, index: Int, info: MediaCodec.BufferInfo, onWritten: () -> Unit) {
            val isConfig = info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0
            val shouldWrite = !isConfig && info.size > 0 && info.presentationTimeUs >= 0
            if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) isDone = true
            if (shouldWrite) {
                muxer.writeSampleData(track, requireNotNull(encoder.getOutputBuffer(index)), info)
                lastWrittenUs = info.presentationTimeUs
            }
            encoder.releaseOutputBuffer(index, false)
            if (shouldWrite) onWritten()
        }
    }

    private companion object {
        const val TIMEOUT_US = 10_000L
        const val SIZE_CHECK_SAMPLES = 30
        const val DEFAULT_AUDIO_BUFFER = 256 * 1024
        const val DEFAULT_FRAME_RATE = 30
        const val MAX_ENCODER_FRAME_RATE = 240
        const val REORDER_MARGIN_US = 500_000L
        const val VBR = MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR
        const val MAX_BITRATE_RAISE = 1.2
        const val MAX_QP = 51

        /** Bitrate modes to try in turn; null keeps the encoder's default when it does not say. */
        fun bitrateModes(capabilities: MediaCodecInfo.EncoderCapabilities?): List<Int?> {
            val modes = listOf(VBR, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR)
                .filter { capabilities?.isBitrateModeSupported(it) == true }
            return modes.ifEmpty { listOf(null) }
        }

        private fun Long.saturatingPlus(other: Long): Long = if (this > Long.MAX_VALUE - other) Long.MAX_VALUE else this + other

        // A missing codec or one that rejects this format is a platform limit, not a
        // broken input. A codec that is merely busy or reclaimed will come back.
        private inline fun <T> codec(what: String, block: () -> T): T = try {
            block()
        } catch (error: MediaCodec.CodecException) {
            if (isTemporary(error)) throw Stop(CompressionStatus.INTERRUPTED, "$what is busy: $error")
            throw Stop(CompressionStatus.UNSUPPORTED, "no $what: $error")
        } catch (error: Exception) {
            throw Stop(CompressionStatus.UNSUPPORTED, "no $what: $error")
        }

        private fun isTemporary(error: MediaCodec.CodecException): Boolean =
            error.isTransient || error.isRecoverable || isReclaimed(error) ||
                (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && error.errorCode == MediaCodec.CodecException.ERROR_INSUFFICIENT_RESOURCE)

        /**
         * The format to decode and the name of a decoder that claims to support it,
         * null when none does. Dolby Vision profile 8 carries an HEVC base layer that
         * any HEVC decoder can play when the device has no Dolby Vision decoder.
         */
        fun findDecoder(trackFormat: MediaFormat): Pair<MediaFormat, String?> {
            val name = decoderFor(trackFormat)
            val isProfile8 = trackFormat.mime == MediaFormat.MIMETYPE_VIDEO_DOLBY_VISION &&
                trackFormat.intOrNull(MediaFormat.KEY_PROFILE) == CodecProfileLevel.DolbyVisionProfileDvheSt
            if (name != null || !isProfile8) return trackFormat to name
            val baseLayer = hevcBaseLayer(trackFormat)
            return baseLayer to decoderFor(baseLayer)
        }

        // Before API 22 the lookup fails for any format that has a frame rate.
        private fun decoderFor(format: MediaFormat): String? = if (Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP_MR1) {
            null
        } else {
            runCatching { MediaCodecList(MediaCodecList.REGULAR_CODECS).findDecoderForFormat(format) }.getOrNull()
        }

        private fun hevcBaseLayer(format: MediaFormat): MediaFormat {
            val width = format.getInteger(MediaFormat.KEY_WIDTH)
            val height = format.getInteger(MediaFormat.KEY_HEIGHT)
            return MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_HEVC, width, height).apply {
                for (key in listOf("csd-0", "csd-1")) {
                    if (format.containsKey(key)) setByteBuffer(key, format.getByteBuffer(key))
                }
                for (key in listOf(
                    MediaFormat.KEY_MAX_INPUT_SIZE, MediaFormat.KEY_FRAME_RATE, MediaFormat.KEY_ROTATION,
                    MediaFormat.KEY_COLOR_STANDARD, MediaFormat.KEY_COLOR_TRANSFER, MediaFormat.KEY_COLOR_RANGE,
                )) {
                    format.intOrNull(key)?.let { setInteger(key, it) }
                }
                format.longOrNull(MediaFormat.KEY_DURATION)?.let { setLong(MediaFormat.KEY_DURATION, it) }
                setInteger(MediaFormat.KEY_PROFILE, CodecProfileLevel.HEVCProfileMain10)
            }
        }

        fun codecCapabilities(codec: MediaCodec, mime: String): MediaCodecInfo.CodecCapabilities? = runCatching {
            val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                codec.codecInfo
            } else {
                MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos.first { it.name == codec.name }
            }
            info.getCapabilitiesForType(mime)
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
