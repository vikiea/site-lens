package dev.vikiea.site_lens

/**
 * 一次远程请求要带的请求头（T6）。
 *
 * 凭证注入与「旧值替换」都在这里完成，只有三样东西：这条请求的地址、它已有的
 * 头、以及该带的那一份凭证。播放入口按**每一次请求**重新走一遍——主清单、每
 * 一个分片、重定向后的 CDN 地址各算一次，所以「分片也带凭证」不是靠一次性的
 * 会话头，而是靠这个函数被反复调用。
 *
 * 凭证只进请求，不出现在任何返回值以外的地方：这里不打印、不缓存、不做日志。
 */
internal object AuthoredHttpRequest {
    /** 只由凭证提供、需要覆盖旧值的两个头。 */
    private val CREDENTIAL_HEADERS = listOf(
        SiteCredentialRecord.HEADER_AUTHORIZATION,
        SiteCredentialRecord.HEADER_COOKIE,
    )

    /**
     * 把 [headers]（凭证给出的那些）合并进 [existing]：同名（忽略大小写）的旧值
     * 被替换，其余的头原样保留。
     *
     * 旧值必须先删再放，否则 `Authorization` 与 `authorization` 会同时出现在
     * 一次请求里，站点收到两份互相矛盾的凭证。
     */
    fun merge(
        existing: Map<String, String>,
        headers: Map<String, String>,
    ): Map<String, String> {
        if (headers.isEmpty()) return existing
        val merged = LinkedHashMap<String, String>(existing)
        for (name in CREDENTIAL_HEADERS) {
            val value = headers[name] ?: continue
            val stale = merged.keys.filter { it.equals(name, ignoreCase = true) }
            for (key in stale) merged.remove(key)
            merged[name] = value
        }
        return merged
    }
}
