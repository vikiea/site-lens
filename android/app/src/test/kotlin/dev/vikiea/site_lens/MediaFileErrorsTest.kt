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

    @Test fun revokedTreeGrantIsPermissionFailure() {
        assertEquals(
            "media_permission",
            MediaFileErrors.code(IllegalArgumentException("MP4 目录权限已失效，请重新选择保存目录")),
        )
        assertEquals(
            "media_permission",
            MediaFileErrors.code(IllegalStateException("Permission denied by provider")),
        )
    }

    @Test fun boundedInspectionFailuresKeepSpecificCodes() {
        assertEquals(
            "media_file_too_large",
            MediaFileErrors.code(IllegalArgumentException("媒体文件过大，无法读取详细信息")),
        )
        assertEquals(
            "media_file_empty",
            MediaFileErrors.code(IllegalArgumentException("媒体文件为空")),
        )
        assertEquals(
            "media_inspection_timeout",
            MediaFileErrors.code(IllegalStateException("媒体检查超时")),
        )
    }
}
