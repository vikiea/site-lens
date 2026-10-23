package dev.vikiea.site_lens

import java.io.ByteArrayInputStream
import java.io.File
import java.io.IOException
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

class VerifiedMediaCopyTest {
    private fun withTarget(body: (File) -> Unit) {
        val root = Files.createTempDirectory("verified-media-copy").toFile()
        try { body(File(root, "retained.media")) } finally { root.deleteRecursively() }
    }

    @Test fun missingDestinationDoesNotOpenTheSource() = withTarget { target ->
        assertFalse(verifyExistingMediaCopy(target, { error("must not open") }, {}))
        assertFalse(target.exists())
    }

    @Test fun identicalPublishedCopyIsReusedWithoutRewritingIt() = withTarget { target ->
        val bytes = byteArrayOf(1, 2, 3, 4)
        target.writeBytes(bytes)
        target.setLastModified(1234567890000L)
        val before = target.lastModified()
        assertTrue(verifyExistingMediaCopy(target, { ByteArrayInputStream(bytes) }, {}))
        assertArrayEquals(bytes, target.readBytes())
        assertEquals(before, target.lastModified())
    }

    @Test fun sameLengthDifferentContentIsRejectedWithoutChangingTheDestination() = withTarget { target ->
        val bytes = byteArrayOf(4, 3, 2, 1)
        target.writeBytes(bytes)
        assertThrows(IllegalArgumentException::class.java) {
            verifyExistingMediaCopy(target, { ByteArrayInputStream(byteArrayOf(1, 2, 3, 4)) }, {})
        }
        assertArrayEquals(bytes, target.readBytes())
    }

    @Test fun matchingEmptyFilesDoNotBecomeAValidCache() = withTarget { target ->
        target.writeBytes(byteArrayOf())
        assertThrows(IllegalArgumentException::class.java) {
            verifyExistingMediaCopy(target, { ByteArrayInputStream(byteArrayOf()) }, {})
        }
        assertEquals(0L, target.length())
    }

    @Test fun cancellationRetainsTheExistingCopy() = withTarget { target ->
        val bytes = byteArrayOf(1, 2, 3)
        target.writeBytes(bytes)
        assertThrows(IllegalStateException::class.java) {
            verifyExistingMediaCopy(target, { ByteArrayInputStream(bytes) }, { error("cancelled") })
        }
        assertArrayEquals(bytes, target.readBytes())
    }

    @Test fun unreadableSourceDoesNotDiscardTheExistingCopy() = withTarget { target ->
        val bytes = byteArrayOf(1, 2, 3)
        target.writeBytes(bytes)
        assertThrows(IOException::class.java) {
            verifyExistingMediaCopy(target, { throw IOException("unreadable") }, {})
        }
        assertArrayEquals(bytes, target.readBytes())
    }
}
