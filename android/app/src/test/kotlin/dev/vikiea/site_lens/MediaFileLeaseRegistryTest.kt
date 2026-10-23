package dev.vikiea.site_lens

import java.io.File
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test

class MediaFileLeaseRegistryTest {
    private val media = MediaFileLeaseRegistry.Scope.file(File("/app/cache/episode.mp4"))

    @Test fun activeReaderRejectsMutationUntilItsFinalRelease() {
        val registry = MediaFileLeaseRegistry()
        val first = registry.acquireRead(media)
        val second = registry.acquireRead(media)
        assertThrows(IllegalStateException::class.java) { registry.acquireMutation(media) }
        first.close()
        first.close()
        assertThrows(IllegalStateException::class.java) { registry.acquireMutation(media) }
        second.close()
        registry.acquireMutation(media).close()
    }

    @Test fun reservedMutationPreventsPlaybackOpeningUntilCommit() {
        val registry = MediaFileLeaseRegistry()
        registry.acquireMutation(media).use {
            assertThrows(IllegalStateException::class.java) { registry.acquireRead(media) }
            assertThrows(IllegalStateException::class.java) { registry.acquireMutation(media) }
        }
        registry.acquireRead(media).close()
    }

    @Test fun aLaterReaderRejectsTheWholeDeletionSetBeforeItsFirstSideEffect() {
        val registry = MediaFileLeaseRegistry()
        val unrelated = MediaFileLeaseRegistry.Scope.file(File("/app/cache/other.mp4"))
        var firstDeleted = false
        registry.acquireRead(media).use {
            assertThrows(IllegalStateException::class.java) {
                registry.mutate(unrelated + media) { firstDeleted = true }
            }
            assertFalse(firstDeleted)
        }
        registry.mutate(unrelated + media) { firstDeleted = true }
        assertTrue(firstDeleted)
    }

    @Test fun taskIdentityBlocksOtherAliasesOfTheSameArtifact() {
        val registry = MediaFileLeaseRegistry()
        val held = media + MediaFileLeaseRegistry.Scope.task("catalog-1")
        registry.acquireRead(held).use {
            assertThrows(IllegalStateException::class.java) {
                registry.acquireMutation(MediaFileLeaseRegistry.Scope.task("catalog-1"))
            }
            registry.acquireMutation(MediaFileLeaseRegistry.Scope.task("catalog-2")).close()
        }
    }

    @Test fun hlsDirectoryProtectsChildrenAndParentButNotPrefixSibling() {
        val registry = MediaFileLeaseRegistry()
        val directory = MediaFileLeaseRegistry.Scope.file(File("/app/cache/episode.hls"))
        registry.acquireRead(directory).use {
            for (path in listOf("/app/cache", "/app/cache/episode.hls", "/app/cache/episode.hls/segment.ts")) {
                assertThrows(IllegalStateException::class.java) {
                    registry.acquireMutation(MediaFileLeaseRegistry.Scope.file(File(path)))
                }
            }
            registry.acquireMutation(MediaFileLeaseRegistry.Scope.file(File("/app/cache/episode.hls-other/segment.ts"))).close()
        }
    }

    @Test fun canonicalPathsHandleFileUrisSpacesAndSymlinks() {
        val root = Files.createTempDirectory("lens-file-lease").toFile()
        try {
            val file = File(root, "集 1.mp4").apply { writeText("video") }
            val link = File(root, "alias.mp4")
            Files.createSymbolicLink(link.toPath(), file.toPath())
            val registry = MediaFileLeaseRegistry()
            registry.acquireRead(MediaFileLeaseRegistry.Scope.source(file.path)).use {
                for (source in listOf(file.toURI().toString(), link.path, File(root, "child/../集 1.mp4").path)) {
                    assertThrows(IllegalStateException::class.java) {
                        registry.acquireMutation(MediaFileLeaseRegistry.Scope.source(source))
                    }
                }
            }
        } finally { root.deleteRecursively() }
    }

    @Test fun documentIdentityProtectsSafWithoutCopyingIt() {
        val registry = MediaFileLeaseRegistry()
        val doc = MediaFileLeaseRegistry.Scope.source("content://provider/document/episode%2Fone")
        registry.acquireRead(doc).use {
            assertThrows(IllegalStateException::class.java) { registry.acquireMutation(doc) }
            registry.acquireMutation(MediaFileLeaseRegistry.Scope.source("content://provider/document/episode%2Ftwo")).close()
        }
        for (raw in listOf("https://remote.example/video.mp4", "content://user:secret@provider/document/one")) {
            assertThrows(IllegalArgumentException::class.java) { MediaFileLeaseRegistry.Scope.source(raw) }
        }
    }

    @Test fun exceptionReleasesMutationAndDoesNotPoisonSubsequentReaders() {
        val registry = MediaFileLeaseRegistry()
        assertThrows(IllegalArgumentException::class.java) {
            registry.mutate(media) { throw IllegalArgumentException("write failed") }
        }
        registry.acquireRead(media).close()
    }

    @Test fun safTreeAndDirectDocumentAliasesShareOneIdentity() {
        val registry = MediaFileLeaseRegistry()
        val direct = MediaFileLeaseRegistry.Scope.source("content://provider/document/primary%3AMovies%2Fepisode+1.mp4")
        registry.acquireRead(direct).use {
            for (alias in listOf(
                "content://provider/tree/primary%3AMovies/document/primary%3aMovies%2fepisode+1.mp4",
                "content://PROVIDER/document/primary%3AMovies%2Fepisode%2B1.mp4?displayName=other#fragment",
            )) {
                assertThrows(IllegalStateException::class.java) {
                    registry.acquireMutation(MediaFileLeaseRegistry.Scope.source(alias))
                }
            }
            registry.acquireMutation(MediaFileLeaseRegistry.Scope.source("content://provider/document/primary%3AMovies%2Fepisode%201.mp4")).close()
            registry.acquireMutation(MediaFileLeaseRegistry.Scope.source("content://other/document/primary%3AMovies%2Fepisode+1.mp4")).close()
        }
    }

    @Test fun safStructureUsesFixedPositionsAndAcceptsEncodedSegmentsAndTrailingSlash() {
        val registry = MediaFileLeaseRegistry()
        val held = MediaFileLeaseRegistry.Scope.source(
            "content://provider/document/primary%3AMovies%2Fepisode%2B1.mp4",
        )
        registry.acquireRead(held).use {
            for (alias in listOf(
                "content://provider/%64ocument/primary%3AMovies%2Fepisode+1.mp4/",
                "content://provider/tree/document/document/primary%3aMovies%2fepisode%2B1.mp4",
            )) {
                assertThrows(IllegalStateException::class.java) {
                    registry.acquireMutation(MediaFileLeaseRegistry.Scope.source(alias))
                }
            }
        }
    }

    @Test fun actualConcurrentMutationCannotRaceAnIncomingReader() {
        val registry = MediaFileLeaseRegistry()
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val completed = CountDownLatch(1)
        val worker = Thread {
            try {
                registry.mutate(media) {
                    entered.countDown()
                    check(release.await(5, TimeUnit.SECONDS))
                }
            } finally { completed.countDown() }
        }
        worker.start()
        try {
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            assertThrows(IllegalStateException::class.java) { registry.acquireRead(media) }
        } finally {
            release.countDown()
            assertTrue(completed.await(5, TimeUnit.SECONDS))
            worker.join(1000)
        }
        registry.acquireRead(media).close()
    }
}
