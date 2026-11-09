package dev.vikiea.site_lens

import java.io.ByteArrayInputStream
import java.io.File
import java.io.FilterInputStream
import java.io.IOException
import java.io.InputStream
import java.io.InterruptedIOException
import java.net.HttpURLConnection
import java.net.URL
import java.nio.file.Files
import java.util.ArrayDeque
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

class ResumableMediaTransferTest {
    @Test
    fun tlsKeyRetryReportsBothAttempts() = fixture { root ->
        val url = URL("https://cdn.example/key.bin?token=secret").toURI()
        val seen = mutableListOf<Int>()
        val diagnostics = mutableListOf<Map<String, Any>>()
        val transfer = ResumableMediaTransfer(
            connectForAttempt = { _, index ->
                seen += index
                if (index == 0) throw javax.net.ssl.SSLHandshakeException("private token=secret")
                FakeConnection(200, mapOf("Content-Length" to "16"), ByteArrayInputStream(ByteArray(16)))
            },
            onAttempt = { diagnostics += it },
            dnsModeForConnection = { "system_route" },
            networkEpochForAttempt = { 12L },
        )
        assertEquals(16L, transfer.transfer(url, url, File(root, "key.part"), "test", maxAttempts = 5))
        assertEquals(listOf(0, 1), seen)
        assertEquals("tls_handshake", diagnostics.first()["failureCategory"])
        assertEquals("completed", diagnostics.last()["outcome"])
        assertEquals(12L, diagnostics.last()["networkEpoch"])
        assertFalse(diagnostics.toString().contains("token"))
        assertFalse(diagnostics.toString().contains("secret"))
    }

    @Test
    fun retryDelayUsesFailureCategoryAndPartialProgress() {
        assertEquals(250L, ResumableMediaTransfer.retryDelayMillis("dns", 0L, 0))
        assertEquals(100L, ResumableMediaTransfer.retryDelayMillis("connection_reset", 10L, 0))
        assertEquals(300L, ResumableMediaTransfer.retryDelayMillis("connection_reset", 0L, 0))
        assertEquals(5_000L, ResumableMediaTransfer.retryDelayMillis("io", 0L, 9))
    }

    @Test
    fun certificateAndHostnameFailuresAreNotRetried() = fixture { root ->
        val url = URL("https://cdn.example/video").toURI()
        val attempts = mutableListOf<Int>()
        val transfer = ResumableMediaTransfer(
            connectForAttempt = { _, attempt ->
                attempts += attempt
                throw javax.net.ssl.SSLPeerUnverifiedException("hostname mismatch")
            },
        )
        assertThrows(MediaTransferFailure::class.java) {
            transfer.transfer(url, url, File(root, "video.part"), "test", maxAttempts = 5)
        }
        assertEquals(listOf(0), attempts)
    }
    @Test
    fun remainingBudgetAndStrategyOffsetAreSharedWithCaller() = fixture { root ->
        val url = URL("https://cdn.example/video").toURI()
        val attempts = mutableListOf<Int>()
        val starts = mutableListOf<Int>()
        val transfer = ResumableMediaTransfer(
            connectForAttempt = { _, attempt ->
                attempts += attempt
                FailingResponseCodeConnection()
            },
            onAttemptStarted = { starts += it },
        )
        val error = assertThrows(MediaTransferFailure::class.java) {
            transfer.transfer(url, url, File(root, "video.part"), "test", maxAttempts = 2, startAttempt = 3)
        }
        assertEquals(listOf(3, 4), attempts)
        assertEquals(listOf(1, 2), starts)
        assertEquals(2, error.attemptsUsed)
        assertEquals(2, error.diagnostics()["attemptsUsed"])
    }

    @Test
    fun authorizationFailureReportsConsumedBudget() = fixture { root ->
        val url = URL("https://cdn.example/video").toURI()
        val transfer = ResumableMediaTransfer(connect = {
            FakeConnection(403, emptyMap(), ByteArrayInputStream(byteArrayOf()))
        })
        val error = assertThrows(MediaAuthorizationException::class.java) {
            transfer.transfer(url, url, File(root, "video.part"), "test", maxAttempts = 3, startAttempt = 2)
        }
        assertEquals(1, error.attemptsUsed)
        assertEquals(403, error.statusCode)
    }

    @Test
    fun headerFailureDiagnosticsContainNoSignedUrlOrProviderMessage() = fixture { root ->
        val url = URL("https://cdn.example/video?auth_key=private-signature").toURI()
        try {
            ResumableMediaTransfer(connect = { FailingResponseCodeConnection() })
                .transfer(url, url, File(root, "secret-path.part"), "test")
            throw AssertionError("expected transfer failure")
        } catch (failure: MediaTransferFailure) {
            assertEquals("response_headers", failure.phase)
            assertEquals("cdn.example", failure.host)
            assertEquals(4, failure.attempt)
            assertEquals("direct", failure.route)
            assertEquals(false, failure.cookiePresent)
            assertEquals(0L, failure.bytesWritten)
            val exposed = failure.toString() + failure.diagnostics().toString()
            assertFalse(exposed.contains("auth_key"))
            assertFalse(exposed.contains("private-signature"))
            assertFalse(exposed.contains("secret-path"))
            assertFalse(exposed.contains("route failed"))
        }
    }

    @Test
    fun bodyFailureKeepsPartialBytesAndReportsReadStage() = fixture { root ->
        val url = URL("https://cdn.example/video").toURI()
        val partial = File(root, "video.part")
        try {
            ResumableMediaTransfer(connect = {
                FakeConnection(200, mapOf("Content-Length" to "6"), FailingInputStream(byteArrayOf(1, 2, 3)))
            }).transfer(url, url, partial, "test")
            throw AssertionError("expected body failure")
        } catch (failure: MediaTransferFailure) {
            assertEquals("body_read", failure.phase)
            assertEquals("connection_reset", failure.reason)
            assertEquals(3L, failure.bytesWritten)
            assertArrayEquals(byteArrayOf(1, 2, 3), partial.readBytes())
        }
    }

    @Test
    fun redirectsRecomputeCookiesInsteadOfForwardingThem() = fixture { root ->
        val first = FakeConnection(302, mapOf("Location" to "https://other.example/video"), ByteArrayInputStream(byteArrayOf()))
        val second = FakeConnection(200, mapOf("Content-Length" to "2"), ByteArrayInputStream(byteArrayOf(1, 2)))
        val responses = ArrayDeque(listOf(first, second))
        val lookedUp = mutableListOf<String>()
        val url = URL("https://cdn.example/video").toURI()
        val partial = File(root, "video.part")
        ResumableMediaTransfer(connect = { responses.removeFirst() }).transfer(
            url, URL("https://site.example/watch/ep-2?token=private#secret").toURI(), partial, "test",
            requestHeaders = mapOf("authorization" to "secret", "x-cdn-auth" to "cdn-secret"),
            requestCookies = { uri ->
                lookedUp.add(uri.host)
                if (uri.host == "cdn.example") "cdn=secret" else null
            },
        )
        assertEquals("https://site.example/watch/ep-2", first.properties["Referer"])
        assertEquals(listOf("cdn.example", "other.example"), lookedUp)
        assertEquals("cdn=secret", first.properties["Cookie"])
        assertNull(second.properties["Cookie"])
        assertEquals("secret", first.properties["authorization"])
        assertNull(second.properties["authorization"])
        assertNull(second.properties["x-cdn-auth"])
        assertArrayEquals(byteArrayOf(1, 2), partial.readBytes())
        assertEquals(false, File(partial.path + ".resume").readText().contains("secret"))
    }

    @Test
    fun redirectTargetIsReportedWithItsOwnRoute() = fixture { root ->
        // A TLS failure during connect() belongs to the connect phase, and the
        // redirect target must be attributed to the route planned for it
        // instead of the hop that had just failed.
        val first = FakeConnection(
            302,
            mapOf("Location" to "https://other.example/video"),
            ByteArrayInputStream(byteArrayOf()),
        )
        val planned = mutableListOf<String>()
        val diagnostics = mutableListOf<Map<String, Any>>()
        val transfer = ResumableMediaTransfer(
            connectForAttempt = { uri, _ ->
                if (uri.host == "other.example") {
                    throw javax.net.ssl.SSLHandshakeException("private details")
                }
                first
            },
            routeForAttempt = { uri, _ ->
                planned += uri.host
                if (uri.host == "other.example") "http_proxy" else "vpn_tun_fake_ip"
            },
            routeForConnection = { "vpn_tun_fake_ip" },
            onAttempt = { diagnostics += it },
        )
        assertThrows(IOException::class.java) {
            transfer.transfer(
                URL("https://cdn.example/video").toURI(),
                URL("https://cdn.example/video").toURI(),
                File(root, "video.part"),
                "test",
                maxAttempts = 1,
            )
        }
        assertEquals(listOf("cdn.example", "other.example"), planned)
        // A raw handshake throw inside connect() is not classified by the
        // transport, so the category stays io; the phase and the route are what
        // this case pins. The old code reported response_headers and the
        // previous hop's route here.
        assertEquals("other.example", diagnostics.last()["host"])
        assertEquals("http_proxy", diagnostics.last()["route"])
        assertEquals("connect", diagnostics.last()["phase"])
        assertFalse(diagnostics.toString().contains("private details"))
    }

    @Test
    fun interruptedBodyResumesWithRangeAndIfRange() = fixture { root ->
        val first = FakeConnection(
            200,
            mapOf("ETag" to "\"v1\"", "Content-Length" to "6"),
            FailingInputStream(byteArrayOf(1, 2, 3)),
        )
        val second = FakeConnection(
            206,
            mapOf(
                "ETag" to "\"v1\"",
                "Content-Range" to "bytes 3-5/6",
                "Content-Length" to "3",
            ),
            ByteArrayInputStream(byteArrayOf(4, 5, 6)),
        )
        val responses = ArrayDeque(listOf(first, second))
        val partial = File(root, "video.part")
        val url = URL("https://cdn.example/video").toURI()
        val size = ResumableMediaTransfer(connect = { responses.removeFirst() })
            .transfer(url, url, partial, "test")
        assertEquals(6L, size)
        assertArrayEquals(byteArrayOf(1, 2, 3, 4, 5, 6), partial.readBytes())
        assertEquals("bytes=3-", second.properties["Range"])
        assertEquals("\"v1\"", second.properties["If-Range"])
        assertNull(second.properties["Cookie"])
    }

    @Test
    fun ignoredRangeReplacesPartialFile() = fixture { root ->
        val partial = File(root, "video.part")
        partial.writeBytes(byteArrayOf(1, 2, 3))
        val url = URL("https://cdn.example/video").toURI()
        val identity = java.security.MessageDigest.getInstance("SHA-256")
            .digest(url.toString().toByteArray())
            .joinToString("") { "%02x".format(it) }
        File(partial.path + ".resume").writeText(
            "identity=$identity\nvalidator=\"v1\"\n",
        )
        val response = FakeConnection(
            200,
            mapOf("ETag" to "\"v1\"", "Content-Length" to "6"),
            ByteArrayInputStream(byteArrayOf(7, 8, 9, 10, 11, 12)),
        )
        ResumableMediaTransfer(connect = { response })
            .transfer(url, url, partial, "test")
        assertArrayEquals(byteArrayOf(7, 8, 9, 10, 11, 12), partial.readBytes())
        assertEquals("bytes=3-", response.properties["Range"])
    }

    @Test
    fun invalid206DoesNotAppend() = fixture { root ->
        val first = FakeConnection(
            200,
            mapOf("ETag" to "\"v1\"", "Content-Length" to "6"),
            FailingInputStream(byteArrayOf(1, 2, 3)),
        )
        val invalid = FakeConnection(
            206,
            mapOf(
                "ETag" to "\"v1\"",
                "Content-Range" to "bytes 0-2/6",
                "Content-Length" to "3",
            ),
            ByteArrayInputStream(byteArrayOf(4, 5, 6)),
        )
        val responses = ArrayDeque(listOf(first, invalid))
        val partial = File(root, "video.part")
        val url = URL("https://cdn.example/video").toURI()
        try {
            ResumableMediaTransfer(connect = { responses.removeFirst() })
                .transfer(url, url, partial, "test")
            throw AssertionError("expected invalid Range")
        } catch (_: IllegalStateException) {
            assertArrayEquals(byteArrayOf(1, 2, 3), partial.readBytes())
        }
    }

    @Test
    fun missingResumeValidatorRestartsFromZero() = fixture { root ->
        val first = FakeConnection(
            200,
            mapOf("ETag" to "\"v1\"", "Content-Length" to "2"),
            FailingInputStream(byteArrayOf(1, 2)),
        )
        val missingValidator = FakeConnection(
            206,
            mapOf(
                "Content-Range" to "bytes 2-3/4",
                "Content-Length" to "2",
            ),
            ByteArrayInputStream(byteArrayOf(3, 4)),
        )
        val replacement = FakeConnection(
            200,
            mapOf("ETag" to "\"v2\"", "Content-Length" to "4"),
            ByteArrayInputStream(byteArrayOf(5, 6, 7, 8)),
        )
        val responses = ArrayDeque(listOf(first, missingValidator, replacement))
        val partial = File(root, "video.part")
        val url = URL("https://cdn.example/video").toURI()
        val size = ResumableMediaTransfer(connect = { responses.removeFirst() })
            .transfer(url, url, partial, "test")
        assertEquals(4L, size)
        assertArrayEquals(byteArrayOf(5, 6, 7, 8), partial.readBytes())
        assertNull(replacement.properties["Range"])
    }

    @Test
    fun bounded206ResponsesContinueUntilTheWholeFileIsPresent() = fixture { root ->
        val first = FakeConnection(
            200,
            mapOf("ETag" to "\"v1\"", "Content-Length" to "2"),
            FailingInputStream(byteArrayOf(1, 2)),
        )
        val second = FakeConnection(
            206,
            mapOf(
                "ETag" to "\"v1\"",
                "Content-Range" to "bytes 2-3/6",
                "Content-Length" to "2",
            ),
            ByteArrayInputStream(byteArrayOf(3, 4)),
        )
        val third = FakeConnection(
            206,
            mapOf(
                "ETag" to "\"v1\"",
                "Content-Range" to "bytes 4-5/6",
                "Content-Length" to "2",
            ),
            ByteArrayInputStream(byteArrayOf(5, 6)),
        )
        val responses = ArrayDeque(listOf(first, second, third))
        val partial = File(root, "video.part")
        val url = URL("https://cdn.example/video").toURI()
        val size = ResumableMediaTransfer(connect = { responses.removeFirst() })
            .transfer(url, url, partial, "test")
        assertEquals(6L, size)
        assertArrayEquals(byteArrayOf(1, 2, 3, 4, 5, 6), partial.readBytes())
        assertEquals("bytes=4-", third.properties["Range"])
        assertEquals("\"v1\"", third.properties["If-Range"])
    }

    @Test
    fun bounded206WithoutValidatorFailsWithinTheRetryBudget() = fixture { root ->
        var requests = 0
        val partial = File(root, "video.part")
        val url = URL("https://cdn.example/video").toURI()
        var failed = false
        try {
            ResumableMediaTransfer(connect = {
                requests++
                FakeConnection(
                    206,
                    mapOf(
                        "Content-Range" to "bytes 0-1/6",
                        "Content-Length" to "2",
                    ),
                    ByteArrayInputStream(byteArrayOf(1, 2)),
                )
            }).transfer(url, url, partial, "test")
        } catch (_: IOException) {
            failed = true
        }
        assertEquals(true, failed)
        assertEquals(5, requests)
    }

    @Test
    fun redirectRetryAdvancesRouteForTheFailedOrigin() = fixture { root ->
        val start = URL("https://cdn.example/start").toURI()
        val redirected = URL("https://other.example/video").toURI()
        val attempts = mutableListOf<Pair<String, Int>>()
        val success = FakeConnection(
            200,
            mapOf("ETag" to "\"v1\"", "Content-Length" to "2"),
            ByteArrayInputStream(byteArrayOf(1, 2)),
        )
        val transfer = ResumableMediaTransfer(
            connectForAttempt = { uri, attempt ->
                attempts += uri.host to attempt
                when (uri.host) {
                    "cdn.example" -> FakeConnection(
                        302,
                        mapOf("Location" to redirected.toString()),
                        ByteArrayInputStream(byteArrayOf()),
                    )
                    else -> if (attempt == 0) FailingResponseCodeConnection() else success
                }
            },
        )
        val partial = File(root, "video.part")
        assertEquals(2L, transfer.transfer(start, start, partial, "test"))
        assertEquals(
            listOf(
                "cdn.example" to 0,
                "other.example" to 0,
                "cdn.example" to 0,
                "other.example" to 1,
            ),
            attempts,
        )
        assertArrayEquals(byteArrayOf(1, 2), partial.readBytes())
    }

    private fun fixture(run: (File) -> Unit) {
        val root = Files.createTempDirectory("site-lens-native-download-").toFile()
        try {
            run(root)
        } finally {
            root.deleteRecursively()
        }
    }

    private class FailingInputStream(bytes: ByteArray) :
        FilterInputStream(ByteArrayInputStream(bytes)) {
        private var failed = false

        override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
            val read = super.read(buffer, offset, length)
            if (read < 0 && !failed) {
                failed = true
                throw InterruptedIOException("connection reset")
            }
            return read
        }
    }

    private class FailingResponseCodeConnection :
        HttpURLConnection(URL("https://other.example/video")) {
        override fun connect() = Unit
        override fun disconnect() = Unit
        override fun usingProxy() = false
        override fun getResponseCode(): Int = throw IOException("route failed")
    }

    private class FakeConnection(
        private val status: Int,
        private val responseHeaders: Map<String, String>,
        private val body: InputStream,
    ) : HttpURLConnection(URL("https://cdn.example/video")) {
        val properties = mutableMapOf<String, String?>()

        override fun connect() = Unit
        override fun disconnect() = Unit
        override fun usingProxy() = false
        override fun getResponseCode() = status
        override fun getHeaderField(name: String): String? = responseHeaders[name]
        override fun getHeaderFieldKey(position: Int): String? = null
        override fun getInputStream(): InputStream = body
        override fun getContentLengthLong(): Long =
            responseHeaders["Content-Length"]?.toLongOrNull() ?: -1L

        override fun setRequestProperty(key: String, value: String?) {
            properties[key] = value
        }
    }
}
