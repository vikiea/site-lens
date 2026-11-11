package dev.vikiea.site_lens

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.nio.file.Files

class NativeDownloadCleanupTest {
    @get:Rule val temporary = TemporaryFolder()

    @Test
    fun deletedTaskRemovesItsLockAndOnlyAnEmptySeries() {
        val root = temporary.newFolder("downloads")
        val series = File(root, "series").apply { mkdir() }
        val lock = File(root, ".first.lock").apply { createNewFile() }
        val neighbor = File(series, "second.media").apply { writeText("media") }
        NativeDownloadCleanup.taskDeleted(root, "first", "series")
        assertFalse(lock.exists())
        assertTrue(neighbor.exists())
        neighbor.delete()
        NativeDownloadCleanup.taskDeleted(root, "second", "series")
        assertFalse(series.exists())
    }

    @Test
    fun startupRetainsOwnedLocksAndUnrelatedFiles() {
        val root = temporary.newFolder("downloads")
        val orphan = File(root, ".orphan.lock").apply { createNewFile() }
        val owned = File(root, ".owned.lock").apply { createNewFile() }
        val other = File(root, "keep.txt").apply { writeText("keep") }
        val empty = File(root, "empty").apply { mkdir() }
        NativeDownloadCleanup.reconcile(root) { it == "orphan" }
        assertFalse(orphan.exists())
        assertFalse(empty.exists())
        assertTrue(owned.exists())
        assertTrue(other.exists())
    }

    @Test
    fun cleanupNeverFollowsSeriesLinksOutsideItsRoot() {
        val root = temporary.newFolder("downloads")
        val outside = temporary.newFolder("outside")
        Files.createSymbolicLink(File(root, "linked").toPath(), outside.toPath())
        NativeDownloadCleanup.taskDeleted(root, "first", "linked")
        NativeDownloadCleanup.taskDeleted(root, "first", "../outside")
        NativeDownloadCleanup.reconcile(root) { true }
        assertTrue(outside.exists())
        assertTrue(Files.isSymbolicLink(File(root, "linked").toPath()))
    }
}
