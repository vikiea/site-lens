package dev.vikiea.site_lens

/**
 * 原生侧唯一的取用点：按档案与地址给出这次请求该带的头。
 *
 * 没有凭证、凭证过期、版本不认识，都是空集合——公开内容照播。凭证不缓存：应用
 * 推来一份新的，下一次请求就用新的。
 */
internal object SiteCredentialSources {
    fun headers(channel: SiteCredentialChannel?, profileId: Int, url: String): Map<String, String> {
        val current = channel ?: return emptyMap()
        return runCatching { current.admissionHeaders(url, profileId) }.getOrDefault(emptyMap())
    }
}
