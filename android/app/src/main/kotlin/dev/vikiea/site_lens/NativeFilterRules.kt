package dev.vikiea.site_lens

import android.util.JsonReader
import android.util.JsonToken
import java.io.File
import java.io.FilterInputStream
import java.io.InputStream
import java.io.InputStreamReader
import java.io.StringReader
import java.nio.charset.CodingErrorAction
import java.security.DigestInputStream
import java.security.MessageDigest

internal data class NativeFilterRule(
    val pattern: String,
    val block: Boolean = true,
    val cosmetic: Boolean = false,
    val hostOnly: Boolean = false,
    val domain: String? = null,
    val domains: List<String> = emptyList(),
    val excludedDomains: List<String> = emptyList(),
    val exception: Boolean = false,
    val resourceTypes: List<String> = emptyList(),
    val thirdParty: Boolean? = null,
    val scriptlet: String? = null,
    val scriptletArgs: List<String> = emptyList(),
)

/** Runs only on the registry's worker; request callbacks never perform I/O. */
internal class NativeFilterRules(private val filesRoot: File) {
    companion object {
        const val MAX_BYTES = 32L * 1024 * 1024
        const val MAX_RULES = 300_000
    }

    private var cachedId: String? = null
    private var cachedRules: List<NativeFilterRule> = emptyList()

    fun load(snapshot: FilterSnapshotDto): List<NativeFilterRule> {
        val id = snapshot.rulesFileId
        if (id == null) {
            require(snapshot.rulesBytes == null) { "过滤快照缺少文件标识" }
            require(snapshot.rules.toByteArray(Charsets.UTF_8).size <= 512 * 1024) { "过滤通道消息过大" }
            return JsonReader(StringReader(snapshot.rules)).use(::parse)
        }
        require(snapshot.rules.isEmpty()) { "过滤快照传输方式冲突" }
        require(Regex("[a-f0-9]{64}").matches(id)) { "过滤快照文件标识无效" }
        val expected = snapshot.rulesBytes ?: error("过滤快照缺少文件大小")
        require(expected in 2..MAX_BYTES) { "过滤规则超过内存保护上限（32 MiB）" }
        val root = File(filesRoot, "filter_payloads")
        require(root.canonicalFile == File(filesRoot.canonicalFile, "filter_payloads")) { "过滤快照目录越界" }
        val file = File(root, "$id.json")
        require(file.canonicalFile == File(root.canonicalFile, "$id.json")) { "过滤快照路径越界" }
        require(file.isFile && file.length() == expected) { "过滤快照文件缺失或大小不匹配" }
        if (id == cachedId) return cachedRules
        val digest = MessageDigest.getInstance("SHA-256")
        val rules = file.inputStream().use { input ->
            val bounded = BoundedInput(input, expected)
            val decoder = Charsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
            val result = JsonReader(InputStreamReader(DigestInputStream(bounded, digest), decoder)).use(::parse)
            require(bounded.count == expected) { "过滤快照读取不完整" }
            result
        }
        require(digest.digest().joinToString("") { "%02x".format(it) } == id) { "过滤快照摘要不匹配" }
        cachedId = id
        cachedRules = rules
        return rules
    }

    private fun parse(reader: JsonReader): List<NativeFilterRule> {
        val rules = ArrayList<NativeFilterRule>()
        reader.beginArray()
        while (reader.hasNext()) {
            require(rules.size < MAX_RULES) { "过滤规则数量超过内存保护上限" }
            var rule = NativeFilterRule(pattern = "")
            reader.beginObject()
            while (reader.hasNext()) {
                val name = reader.nextName()
                if (reader.peek() == JsonToken.NULL) {
                    reader.nextNull()
                    continue
                }
                rule = when (name) {
                    "pattern" -> rule.copy(pattern = reader.nextString())
                    "block" -> rule.copy(block = reader.nextBoolean())
                    "cosmetic" -> rule.copy(cosmetic = reader.nextBoolean())
                    "hostOnly" -> rule.copy(hostOnly = reader.nextBoolean())
                    "domain" -> rule.copy(domain = reader.nextString())
                    "domains" -> rule.copy(domains = strings(reader))
                    "excludedDomains" -> rule.copy(excludedDomains = strings(reader))
                    "exception" -> rule.copy(exception = reader.nextBoolean())
                    "resourceTypes" -> rule.copy(resourceTypes = strings(reader))
                    "thirdParty" -> rule.copy(thirdParty = reader.nextBoolean())
                    "scriptlet" -> rule.copy(scriptlet = reader.nextString())
                    "scriptletArgs" -> rule.copy(scriptletArgs = strings(reader))
                    else -> { reader.skipValue(); rule }
                }
            }
            reader.endObject()
            require(rule.pattern.isNotEmpty()) { "过滤规则模式为空" }
            rules.add(rule)
        }
        reader.endArray()
        require(reader.peek() == JsonToken.END_DOCUMENT) { "过滤快照包含尾部数据" }
        return rules.toList()
    }

    private fun strings(reader: JsonReader): List<String> {
        val values = ArrayList<String>()
        reader.beginArray()
        while (reader.hasNext()) values.add(reader.nextString())
        reader.endArray()
        return values
    }

    private class BoundedInput(input: InputStream, private val limit: Long) : FilterInputStream(input) {
        var count = 0L
            private set
        override fun read(): Int = `in`.read().also { value ->
            if (value >= 0) { count++; require(count <= limit) { "过滤快照文件变大" } }
        }
        override fun read(buffer: ByteArray, offset: Int, length: Int): Int =
            `in`.read(buffer, offset, length).also { size ->
                if (size > 0) { count += size; require(count <= limit) { "过滤快照文件变大" } }
            }
    }
}
