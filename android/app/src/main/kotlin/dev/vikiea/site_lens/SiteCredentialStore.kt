package dev.vikiea.site_lens

import android.content.Context

/**
 * 原生侧的凭证落点（T4）。
 *
 * 选型：普通 `SharedPreferences`（`MODE_PRIVATE`，落在应用私有目录里），不引入
 * `androidx.security:security-crypto` 的 `EncryptedSharedPreferences`：
 *
 * - 这份副本是**应用侧那一份的镜像**，唯一真相在 `flutter_secure_storage`。它的
 *   价值是进程边界内的可用性，不是长期保管；泄露它的后果与泄露进程内存相同，
 *   并不额外扩大暴露面。
 * - `security-crypto` 要新增一个 AndroidX 依赖，并自带 Keystore 迁移路径：迁移
 *   失败就是「原生侧静默没有凭证」，把一个可以现场看到的坏状态换成更脆的读路径。
 * - 落点刻意避开 Dart 侧安全存储的键空间与备份路径：键名沿用应用侧的
 *   `site_credential_v1.<profileId>.<accountId>`，方便两份副本对账。
 *
 * 这个类只存字符串、不解释内容；规格（版本、必填、上限）由
 * [SiteCredentialRecord] 决定。任何一条日志都不记录值。
 */
internal class SiteCredentialPreferencesStore(context: Context) : SiteCredentialChannel.Store {
    private val preferences = context.applicationContext
        .getSharedPreferences(FILE_NAME, Context.MODE_PRIVATE)

    override fun read(profileId: Int): String? =
        preferences.getString(key(profileId), null)

    override fun write(profileId: Int, raw: String) {
        // 一次 commit 就是一次整份替换：进程被杀也不会留下半份记录。
        check(preferences.edit().putString(key(profileId), raw).commit()) { "无法写入站点凭证" }
    }

    override fun delete(profileId: Int) {
        check(preferences.edit().remove(key(profileId)).commit()) { "无法清除站点凭证" }
    }

    fun profileIds(): Set<Int> = preferences.all.keys
        .filter { it.startsWith(KEY_PREFIX) }
        .mapNotNull { it.substring(KEY_PREFIX.length).substringBefore('.').toIntOrNull() }
        .toSet()

    override fun toString(): String =
        "SiteCredentialPreferencesStore(profiles=${profileIds().size})"

    companion object {
        const val FILE_NAME = "site_credential_v1"
        private const val KEY_PREFIX = "site_credential_v1."

        fun key(
            profileId: Int,
            accountId: String = SiteCredentialRecord.DEFAULT_ACCOUNT_ID,
        ): String = "$KEY_PREFIX$profileId.$accountId"

        /** 档案被删除时一并清掉它那一份。 */
        fun clearProfile(context: Context, profileId: Int) {
            SiteCredentialPreferencesStore(context).delete(profileId)
        }
    }
}
