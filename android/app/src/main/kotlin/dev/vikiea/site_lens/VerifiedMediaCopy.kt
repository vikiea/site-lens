package dev.vikiea.site_lens

import java.io.File
import java.io.InputStream
import java.security.MessageDigest

/** Caller holds the destination mutation reservation and source read lease. */
internal fun verifyExistingMediaCopy(
    target: File,
    openSource: () -> InputStream,
    checkActive: () -> Unit,
): Boolean {
    if (!target.exists()) return false
    require(target.isFile) { "目标副本不是文件" }
    fun fingerprint(open: () -> InputStream): Pair<Long, ByteArray> {
        val digest = MessageDigest.getInstance("SHA-256")
        var count = 0L
        open().use { input ->
            val buffer = ByteArray(128 * 1024)
            while (true) {
                checkActive()
                val read = input.read(buffer)
                if (read < 0) break
                digest.update(buffer, 0, read)
                count += read
            }
        }
        return count to digest.digest()
    }
    val expected = fingerprint(openSource)
    val actual = fingerprint { target.inputStream() }
    checkActive()
    require(expected.first > 0 && expected.first == actual.first &&
        expected.second.contentEquals(actual.second)) { "已有缓存副本与来源不一致" }
    return true
}
