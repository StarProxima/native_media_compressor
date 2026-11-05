package io.github.starproxima.native_media_compressor

import java.io.File
import java.io.IOException

/**
 * A temporary file next to the destination that replaces it only on success, so a
 * failed compression leaves the destination as it was and a source can be its own
 * destination. Being in the same directory makes the final move a rename.
 */
internal class StagedOutput private constructor(private val destination: File, val file: File) {
    /** Moves the output over the destination when [reply] is compressed, otherwise drops it. */
    fun finish(reply: CompressionReply): CompressionReply {
        if (reply.status != CompressionStatus.COMPRESSED) {
            file.delete()
            return reply
        }
        if (!file.renameTo(destination)) {
            file.delete()
            return CompressionReply(CompressionStatus.FAILED, message = "cannot move the output to $destination")
        }
        return reply
    }

    fun discard() {
        file.delete()
    }

    companion object {
        /** Creates the temporary file; throws when the destination's directory is not writable. */
        fun create(destinationPath: String): StagedOutput {
            val destination = File(destinationPath).absoluteFile
            val directory = destination.parentFile ?: throw IOException("$destinationPath has no directory")
            // The extension stays last: some writers and readers pick the format by it.
            val suffix = destination.extension.takeIf { it.isNotEmpty() }?.let { ".$it" }
            val file = File.createTempFile(".${destination.nameWithoutExtension}.part-", suffix, directory)
            return StagedOutput(destination, file)
        }
    }
}
