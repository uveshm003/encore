package com.encore.encore_media

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.Executors

/**
 * Native media I/O for Encore on Android (requirement §6.1 "Media I/O").
 *
 * Mirrors the Apple implementation's contract: turn any file the platform can
 * read into a canonical 32-bit float WAV, and turn such a WAV back into a
 * compressed file. Decoding uses MediaExtractor/MediaCodec, which covers every
 * format the device itself can play.
 *
 * Unlike AVFoundation, MediaCodec does not resample or remix, so this decodes
 * at the source's own rate and channel count and reports what it produced; the
 * Dart side converts to the engine's format with its own resampler rather than
 * duplicating that DSP here.
 */
class EncoreMediaPlugin :
    FlutterPlugin,
    MethodCallHandler {

    private lateinit var channel: MethodChannel
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    private companion object {
        const val CHANNEL_NAME = "com.encore/media"
        const val TIMEOUT_US = 10_000L

        /** Extensions Android's own decoders handle. */
        val DECODABLE = listOf(
            "wav", "wave", "mp3", "m4a", "mp4", "aac", "adts", "flac",
            "ogg", "oga", "opus", "amr", "mkv", "3gp", "m4b",
        )

        /** AAC in an MP4 container is what MediaMuxer can write. */
        val ENCODABLE = listOf("m4a", "aac", "mp4", "wav")
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        worker.shutdown()
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "capabilities" -> result.success(
                mapOf(
                    "decodableExtensions" to DECODABLE,
                    "encodableExtensions" to ENCODABLE,
                ),
            )

            "probe" -> {
                val path = call.argument<String>("path")
                if (path == null) {
                    result.error("bad_arguments", "probe requires a 'path'", null)
                    return
                }
                runAsync(result) { probe(path) }
            }

            "decodeToWav" -> {
                val source = call.argument<String>("source")
                val destination = call.argument<String>("destination")
                if (source == null || destination == null) {
                    result.error(
                        "bad_arguments",
                        "decodeToWav requires 'source' and 'destination'",
                        null,
                    )
                    return
                }
                runAsync(result) { decodeToWav(source, destination) }
            }

            "encodeFromWav" -> {
                val source = call.argument<String>("source")
                val destination = call.argument<String>("destination")
                if (source == null || destination == null) {
                    result.error(
                        "bad_arguments",
                        "encodeFromWav requires 'source' and 'destination'",
                        null,
                    )
                    return
                }
                val bitRate = call.argument<Int>("bitRate") ?: 256_000
                runAsync(result) { encodeFromWav(source, destination, bitRate) }
            }

            "freeSpace" -> {
                val path = call.argument<String>("path")
                if (path == null) {
                    result.error("bad_arguments", "freeSpace requires a 'path'", null)
                    return
                }
                result.success(freeSpace(path))
            }

            else -> result.notImplemented()
        }
    }

    // ------------------------------------------------------------- operations

    /**
     * Bytes available to this app on the volume holding [path], or null if it
     * cannot be read.
     *
     * [StatFs.getAvailableBytes] rather than `freeBytes`: the difference is the
     * reserve the filesystem keeps for root, which an app cannot write into, so
     * `freeBytes` would promise space that a separation cannot actually use.
     */
    private fun freeSpace(path: String): Long? = try {
        val target = File(path).let { if (it.exists()) it else it.parentFile }
        target?.let { StatFs(it.absolutePath).availableBytes }
    } catch (_: IllegalArgumentException) {
        null
    } catch (_: SecurityException) {
        null
    }

    private fun probe(path: String): Map<String, Any> {
        val file = File(path)
        if (!file.exists()) throw MediaError.NotFound(path)

        if (path.substringAfterLast('.', "").lowercase() in setOf("wav", "wave")) {
            // The muxer never produces WAV, and MediaExtractor's frame counts
            // for it are unreliable; the header says it exactly.
            val info = WavIo.readInfo(file)
            return mapOf(
                "sampleRate" to info.sampleRate,
                "channelCount" to info.channelCount,
                "frameCount" to info.frameCount,
                "durationMs" to
                    if (info.sampleRate > 0) info.frameCount * 1000 / info.sampleRate else 0L,
            )
        }

        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(path)
            val track = selectAudioTrack(extractor)
            val format = extractor.getTrackFormat(track)
            val sampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            val channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            val durationUs =
                if (format.containsKey(MediaFormat.KEY_DURATION)) {
                    format.getLong(MediaFormat.KEY_DURATION)
                } else {
                    0L
                }
            return mapOf(
                "sampleRate" to sampleRate,
                "channelCount" to channels,
                "frameCount" to durationUs * sampleRate / 1_000_000L,
                "durationMs" to durationUs / 1000L,
            )
        } finally {
            extractor.release()
        }
    }

    private fun decodeToWav(source: String, destination: String): Map<String, Any> {
        val sourceFile = File(source)
        if (!sourceFile.exists()) throw MediaError.NotFound(source)
        File(destination).let { it.parentFile?.mkdirs(); if (it.exists()) it.delete() }

        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            extractor.setDataSource(source)
            val track = selectAudioTrack(extractor)
            extractor.selectTrack(track)
            val inputFormat = extractor.getTrackFormat(track)
            val mime = inputFormat.getString(MediaFormat.KEY_MIME)
                ?: throw MediaError.Unsupported("The audio track has no type.")

            var sampleRate = inputFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            var channelCount = inputFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)

            codec = MediaCodec.createDecoderByType(mime)
            codec.configure(inputFormat, null, null, 0)
            codec.start()

            var writer: WavIo.FloatWriter? = null
            val bufferInfo = MediaCodec.BufferInfo()
            var sawInputEnd = false
            var sawOutputEnd = false

            try {
                while (!sawOutputEnd) {
                    if (!sawInputEnd) {
                        val index = codec.dequeueInputBuffer(TIMEOUT_US)
                        if (index >= 0) {
                            val buffer = codec.getInputBuffer(index)!!
                            val size = extractor.readSampleData(buffer, 0)
                            if (size < 0) {
                                codec.queueInputBuffer(
                                    index, 0, 0, 0,
                                    MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                                )
                                sawInputEnd = true
                            } else {
                                codec.queueInputBuffer(
                                    index, 0, size, extractor.sampleTime, 0,
                                )
                                extractor.advance()
                            }
                        }
                    }

                    when (val index = codec.dequeueOutputBuffer(bufferInfo, TIMEOUT_US)) {
                        MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                            // The real output format only becomes known here.
                            val output = codec.outputFormat
                            sampleRate = output.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                            channelCount = output.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                        }
                        MediaCodec.INFO_TRY_AGAIN_LATER -> Unit
                        else -> {
                            if (index >= 0) {
                                if (writer == null) {
                                    writer = WavIo.FloatWriter(
                                        File(destination), sampleRate, channelCount,
                                    )
                                }
                                val buffer = codec.getOutputBuffer(index)!!
                                if (bufferInfo.size > 0) {
                                    buffer.position(bufferInfo.offset)
                                    buffer.limit(bufferInfo.offset + bufferInfo.size)
                                    val shorts = buffer.order(ByteOrder.LITTLE_ENDIAN)
                                        .asShortBuffer()
                                    val samples = ShortArray(shorts.remaining())
                                    shorts.get(samples)
                                    writer.writeInt16(samples, samples.size)
                                }
                                codec.releaseOutputBuffer(index, false)
                                if (bufferInfo.flags and
                                    MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                                ) {
                                    sawOutputEnd = true
                                }
                            }
                        }
                    }
                }
            } finally {
                writer?.close()
            }

            val frames = writer?.frameCount ?: 0L
            if (frames == 0L) {
                throw MediaError.Corrupt("No audio could be decoded from this file.")
            }
            return mapOf(
                "sampleRate" to sampleRate,
                "channelCount" to channelCount,
                "frameCount" to frames,
                "durationMs" to if (sampleRate > 0) frames * 1000 / sampleRate else 0L,
                "sourceSampleRate" to sampleRate,
                "sourceChannelCount" to channelCount,
            )
        } finally {
            try { codec?.stop() } catch (_: Exception) { }
            codec?.release()
            extractor.release()
        }
    }

    private fun encodeFromWav(
        source: String,
        destination: String,
        bitRate: Int,
    ): Map<String, Any> {
        val sourceFile = File(source)
        if (!sourceFile.exists()) throw MediaError.NotFound(source)
        File(destination).let { it.parentFile?.mkdirs(); if (it.exists()) it.delete() }

        val info = WavIo.readInfo(sourceFile)
        val format = MediaFormat.createAudioFormat(
            MediaFormat.MIMETYPE_AUDIO_AAC, info.sampleRate, info.channelCount,
        ).apply {
            setInteger(
                MediaFormat.KEY_AAC_PROFILE,
                MediaCodecInfo.CodecProfileLevel.AACObjectLC,
            )
            setInteger(MediaFormat.KEY_BIT_RATE, bitRate)
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 1 shl 16)
        }

        val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        codec.start()
        val muxer = MediaMuxer(destination, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)

        var trackIndex = -1
        var muxing = false
        val bufferInfo = MediaCodec.BufferInfo()
        var framesWritten = 0L
        var presentationUs = 0L

        try {
            val pending = ArrayDeque<ShortArray>()
            WavIo.forEachInt16Block(sourceFile, info) { samples, count ->
                pending.addLast(samples.copyOf(count))
            }
            var queueIndex = 0
            var sawInputEnd = false
            var sawOutputEnd = false

            while (!sawOutputEnd) {
                if (!sawInputEnd) {
                    val index = codec.dequeueInputBuffer(TIMEOUT_US)
                    if (index >= 0) {
                        val buffer = codec.getInputBuffer(index)!!
                        buffer.clear()
                        if (queueIndex >= pending.size) {
                            codec.queueInputBuffer(
                                index, 0, 0, presentationUs,
                                MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                            )
                            sawInputEnd = true
                        } else {
                            val block = pending.elementAt(queueIndex++)
                            // A block may be larger than one input buffer, so
                            // only as much as fits is queued at a time.
                            val capacity = buffer.capacity() / 2
                            val count = minOf(capacity, block.size)
                            val bytes = ByteBuffer.allocate(count * 2)
                                .order(ByteOrder.LITTLE_ENDIAN)
                            for (i in 0 until count) bytes.putShort(block[i])
                            buffer.put(bytes.array(), 0, count * 2)
                            codec.queueInputBuffer(index, 0, count * 2, presentationUs, 0)
                            val frames = count / info.channelCount
                            framesWritten += frames
                            presentationUs += frames * 1_000_000L / info.sampleRate
                            if (count < block.size) {
                                // Put the remainder back for the next buffer.
                                pending.removeAt(--queueIndex)
                                pending.add(queueIndex, block.copyOfRange(count, block.size))
                            }
                        }
                    }
                }

                when (val index = codec.dequeueOutputBuffer(bufferInfo, TIMEOUT_US)) {
                    MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        trackIndex = muxer.addTrack(codec.outputFormat)
                        muxer.start()
                        muxing = true
                    }
                    MediaCodec.INFO_TRY_AGAIN_LATER -> Unit
                    else -> {
                        if (index >= 0) {
                            val buffer = codec.getOutputBuffer(index)!!
                            val isConfig = bufferInfo.flags and
                                MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0
                            if (!isConfig && bufferInfo.size > 0 && muxing) {
                                buffer.position(bufferInfo.offset)
                                buffer.limit(bufferInfo.offset + bufferInfo.size)
                                muxer.writeSampleData(trackIndex, buffer, bufferInfo)
                            }
                            codec.releaseOutputBuffer(index, false)
                            if (bufferInfo.flags and
                                MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                            ) {
                                sawOutputEnd = true
                            }
                        }
                    }
                }
            }
        } finally {
            try { codec.stop() } catch (_: Exception) { }
            codec.release()
            try { if (muxing) muxer.stop() } catch (_: Exception) { }
            muxer.release()
        }

        return mapOf(
            "sampleRate" to info.sampleRate,
            "channelCount" to info.channelCount,
            "frameCount" to framesWritten,
            "bitRate" to bitRate,
        )
    }

    // ---------------------------------------------------------------- helpers

    private fun selectAudioTrack(extractor: MediaExtractor): Int {
        for (index in 0 until extractor.trackCount) {
            val mime = extractor.getTrackFormat(index).getString(MediaFormat.KEY_MIME)
            if (mime?.startsWith("audio/") == true) return index
        }
        throw MediaError.Unsupported("This file contains no audio.")
    }

    /** Runs [body] off the platform thread and always answers on it. */
    private fun runAsync(result: Result, body: () -> Map<String, Any>) {
        worker.execute {
            try {
                val value = body()
                main.post { result.success(value) }
            } catch (error: MediaError) {
                main.post { result.error(error.code, error.message, null) }
            } catch (error: Throwable) {
                main.post {
                    result.error(
                        "decode_failed",
                        error.message ?: "The audio file could not be read.",
                        error.toString(),
                    )
                }
            }
        }
    }
}
