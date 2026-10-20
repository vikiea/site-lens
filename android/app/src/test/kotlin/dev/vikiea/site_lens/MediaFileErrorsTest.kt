package dev.vikiea.site_lens

import java.io.FileNotFoundException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class MediaFileErrorsTest {
    @Test fun missingDocument() {
        assertEquals("media_file_missing", MediaFileErrors.code(FileNotFoundException("missing")))
    }
    @Test fun providerFlattensMissingDocument() {
        assertEquals("media_file_missing", MediaFileErrors.code(IllegalArgumentException(
            "Failed to determine if primary:Download/a.mp4 is child of primary:Download: " +
                "java.io.FileNotFoundException: Missing file for primary:Download/a.mp4",
        )))
    }
    @Test fun nestedMissingDocument() {
        assertEquals("media_file_missing", MediaFileErrors.code(IllegalStateException(FileNotFoundException())))
    }
    @Test fun permissionFailureTakesPriority() {
        assertEquals("media_permission", MediaFileErrors.code(FileNotFoundException().apply {
            initCause(SecurityException("revoked"))
        }))
    }
    @Test fun unrelatedArgumentsAreNotMissingFiles() {
        assertNull(MediaFileErrors.code(IllegalArgumentException("Failed to determine if URI is child of root")))
        assertNull(MediaFileErrors.code(IllegalArgumentException("Missing file name")))
        assertNull(MediaFileErrors.code(IllegalStateException("codec unavailable")))
    }
}
