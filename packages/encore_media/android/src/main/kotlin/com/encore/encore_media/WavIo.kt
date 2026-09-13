package com.encore.encore_media

import java.io.BufferedOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Minimal RIFF/WAVE reader and writer.
 *
 * The app's interchange format between Dart and the platform is a 32-bit float
 * WAV, so the plugin only has to write that one shape on the way out and read
 * the handful of shapes it might be handed on the way in.
 */
internal object WavIo {

    /** Header fields of a WAV file. */
    data class Info(
        val sampleRate: Int,
        val channelCount: Int,
        val bitsPerSample: Int,
        val isFloat: Boolean,
        val dataOffset: Long,
        val dataLength: Long,
    ) {
        val bytesPerFrame: Int get() = channelCount * (bitsPerSample / 8)
        val frameCount: Long get() = if (bytesPerFrame == 0) 0 else dataLength / bytesPerFrame
    }

    fun readInfo(file: File): Info {
        RandomAccessFile(file, "r").use { handle ->
            val riff = ByteArray(12)
            if (handle.read(riff) < 12) throw MediaError.Corrupt("The WAV file is truncated.")
            if (String(riff, 0, 4) != "RIFF" || String(riff, 8, 4) != "WAVE") {
                throw MediaError.Unsupported("This is not a WAV file.")
            }

            var sampleRate = 0
            var channelCount = 0
            var bitsPerSample = 0
            var isFloat = false
            var position = 12L
            val length = handle.length()

            while (position + 8 <= length) {
                handle.seek(position)
                val header = ByteArray(8)
                if (handle.read(header) < 8) break
                val id = String(header, 0, 4)
                val size = ByteBuffer.wrap(header, 4, 4)
                    .order(ByteOrder.LITTLE_ENDIAN).int.toLong() and 0xFFFFFFFFL
                val body = position + 8

                if (id == "fmt ") {
                    val fmt = ByteArray(minOf(size, 40L).toInt())
                    handle.seek(body)
                    handle.read(fmt)
                    val buffer = ByteBuffer.wrap(fmt).order(ByteOrder.LITTLE_ENDIAN)
                    var tag = buffer.getShort(0).toInt() and 0xFFFF
                    channelCount = buffer.getShort(2).toInt() and 0xFFFF
                    sampleRate = buffer.getInt(4)
                    bitsPerSample = buffer.getShort(14).toInt() and 0xFFFF
                    // WAVE_FORMAT_EXTENSIBLE carries the real tag in its GUID.
                    if (tag == 0xFFFE && fmt.size >= 26) {
                        tag = buffer.getShort(24).toInt() and 0xFFFF
                    }
                    isFloat = tag == 3
                    if (tag != 1 && tag != 3) {
                        throw MediaError.Unsupported("This WAV file is compressed.")
                    }
                } else if (id == "data") {
                    if (sampleRate == 0 || channelCount == 0) {
                        throw MediaError.Corrupt("The WAV file has no format header.")
                    }
                    val available = length - body
                    val dataLength = if (size == 0L || size > available) available else size
                    return Info(
                        sampleRate = sampleRate,
                        channelCount = channelCount,
                        bitsPerSample = bitsPerSample,
                        isFloat = isFloat,
                        dataOffset = body,
                        dataLength = dataLength,
                    )
                }
                position = body + size + (size and 1L)
            }
            throw MediaError.Corrupt("The WAV file has no audio data.")
        }
    }

    /**
     * Streams a WAV's samples as interleaved 16-bit PCM, whatever it holds.
     *
     * The encoder wants 16-bit input, so this converts on the way through
     * rather than materialising the whole file.
     */
    inline fun forEachInt16Block(
        file: File,
        info: Info,
        framesPerBlock: Int = 8192,
        onBlock: (ShortArray, Int) -> Unit,
    ) {
        RandomAccessFile(file, "r").use { handle ->
            handle.seek(info.dataOffset)
            val bytesPerSample = info.bitsPerSample / 8
            val raw = ByteArray(framesPerBlock * info.bytesPerFrame)
            val out = ShortArray(framesPerBlock * info.channelCount)
            var remaining = info.dataLength

            while (remaining > 0) {
                val wanted = minOf(remaining, raw.size.toLong()).toInt()
                val read = handle.read(raw, 0, wanted)
                if (read <= 0) break
                val frames = read / info.bytesPerFrame
                val buffer = ByteBuffer.wrap(raw, 0, read).order(ByteOrder.LITTLE_ENDIAN)
                val samples = frames * info.channelCount
                for (i in 0 until samples) {
                    val offset = i * bytesPerSample
                    out[i] = when {
                        info.isFloat && info.bitsPerSample == 32 ->
                            floatToShort(buffer.getFloat(offset))
                        info.bitsPerSample == 16 -> buffer.getShort(offset)
                        info.bitsPerSample == 8 ->
                            (((raw[offset].toInt() and 0xFF) - 128) shl 8).toShort()
                        info.bitsPerSample == 24 -> {
                            val value = (raw[offset].toInt() and 0xFF) or
                                ((raw[offset + 1].toInt() and 0xFF) shl 8) or
                                (raw[offset + 2].toInt() shl 16)
                            (value shr 8).toShort()
                        }
                        info.bitsPerSample == 32 -> (buffer.getInt(offset) shr 16).toShort()
                        else -> 0
                    }
                }
                onBlock(out, samples)
                remaining -= read
            }
        }
    }

    fun floatToShort(value: Float): Short {
        val scaled = Math.round(value * 32768.0f)
        return when {
            scaled > 32767 -> 32767
            scaled < -32768 -> -32768
            else -> scaled.toShort()
        }.toShort()
    }

    /**
     * Writes 32-bit float WAV incrementally.
     *
     * The frame count is not known until the decoder finishes, so the header is
     * written with placeholder lengths and patched when the file is closed.
     */
    class FloatWriter(
        private val file: File,
        private val sampleRate: Int,
        private val channelCount: Int,
    ) : AutoCloseable {
        private val stream = BufferedOutputStream(FileOutputStream(file), 1 shl 16)
        private var dataBytes = 0L

        init {
            file.parentFile?.mkdirs()
            stream.write(header(0))
        }

        /** Appends [count] interleaved 16-bit samples, converted to float. */
        fun writeInt16(samples: ShortArray, count: Int) {
            val bytes = ByteArray(count * 4)
            val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
            for (i in 0 until count) {
                buffer.putFloat(i * 4, samples[i] / 32768.0f)
            }
            stream.write(bytes)
            dataBytes += bytes.size
        }

        val frameCount: Long
            get() = if (channelCount == 0) 0 else dataBytes / (channelCount * 4L)

        override fun close() {
            stream.flush()
            stream.close()
            RandomAccessFile(file, "rw").use { handle ->
                handle.seek(0)
                handle.write(header(dataBytes))
            }
        }

        private fun header(dataLength: Long): ByteArray {
            val bytes = ByteArray(44)
            val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
            val bytesPerSample = 4
            System.arraycopy("RIFF".toByteArray(), 0, bytes, 0, 4)
            buffer.putInt(4, (36 + dataLength).toInt())
            System.arraycopy("WAVE".toByteArray(), 0, bytes, 8, 4)
            System.arraycopy("fmt ".toByteArray(), 0, bytes, 12, 4)
            buffer.putInt(16, 16)
            buffer.putShort(20, 3) // IEEE float
            buffer.putShort(22, channelCount.toShort())
            buffer.putInt(24, sampleRate)
            buffer.putInt(28, sampleRate * channelCount * bytesPerSample)
            buffer.putShort(32, (channelCount * bytesPerSample).toShort())
            buffer.putShort(34, (bytesPerSample * 8).toShort())
            System.arraycopy("data".toByteArray(), 0, bytes, 36, 4)
            buffer.putInt(40, dataLength.toInt())
            return bytes
        }
    }
}

/** Failures the plugin reports back to Dart with a stable code. */
internal sealed class MediaError(val code: String, message: String) : Exception(message) {
    class NotFound(path: String) : MediaError("not_found", "The file could not be found: $path")
    class Unsupported(message: String) : MediaError("unsupported", message)
    class Corrupt(message: String) : MediaError("decode_failed", message)
}
