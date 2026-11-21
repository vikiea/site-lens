package dev.vikiea.site_lens

import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DefaultHttpDataSource

/**
 * 远程媒体唯一用的 HTTP 数据来源：允许跨协议重定向（站点常把 http 清单跳到
 * https CDN），其他全部用 Media3 的默认值。凭证由
 * [SiteCredentialDataSource] 在每次请求时追加。
 */
internal object HttpDataSourceFactory {
    fun create(): DataSource = DefaultHttpDataSource.Factory()
        .setAllowCrossProtocolRedirects(true)
        .createDataSource()
}
