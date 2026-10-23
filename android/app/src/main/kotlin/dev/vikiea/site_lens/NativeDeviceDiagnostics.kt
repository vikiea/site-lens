package dev.vikiea.site_lens

import android.app.ActivityManager
import android.app.NotificationManager
import android.content.Context
import android.content.pm.PackageManager
import android.media.MediaCodecList
import android.net.ConnectivityManager
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.os.Handler
import android.os.Looper
import androidx.work.WorkManager
import java.util.concurrent.TimeUnit
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import org.json.JSONArray
import org.json.JSONObject

/** Passive Android capability reader. Every method only observes process/OS state. */
class NativeDeviceDiagnostics(
    context: Context,
    private val multicastLockHeld: () -> Boolean?,
) : DeviceDiagnosticsApi {
    private val appContext = context.applicationContext
    private val executor: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "site-lens-device-diagnostics").apply { isDaemon = true }
    }
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var disposed = false
    private val pending = mutableMapOf<Long, () -> Unit>()
    private var requestId = 0L

    override fun readSnapshot(callback: (Result<DeviceDiagnosticsSnapshot>) -> Unit) {
        query(callback) { readSnapshotNow() }
    }

    override fun readCodecInventory(callback: (Result<List<CodecDescriptor>>) -> Unit) {
        // The app-scoped Dart service owns the five-minute cache. A second
        // engine-lifetime cache would extend stale results past that deadline.
        query(callback) { readCodecsNow() }
    }

    private fun <T> query(callback: (Result<T>) -> Unit, read: () -> T) {
        if (disposed) {
            callback(Result.failure(IllegalStateException("diagnostics_disposed")))
            return
        }
        val id = ++requestId
        pending[id] = { callback(Result.failure(IllegalStateException("diagnostics_disposed"))) }
        executor.execute {
            val result = runCatching(read)
            main.post {
                if (pending.remove(id) != null) callback(result)
            }
        }
    }

    fun dispose() {
        disposed = true
        val cancelled = pending.values.toList()
        pending.clear()
        cancelled.forEach { it() }
        executor.shutdownNow()
    }

    private fun readSnapshotNow(): DeviceDiagnosticsSnapshot {
        val now = System.currentTimeMillis()
        val packageInfo = appContext.packageManager.getPackageInfo(appContext.packageName, 0)
        val webQuery = runCatching { NativeWebCapabilityEvaluator.evaluate(appContext) }
        val web = webQuery.getOrNull()
        val rows = mutableListOf<CapabilityRecord>()

        rows += row(
            id = "platform.android.api",
            state = CapabilityState.SUPPORTED,
            effective = true,
            observed = Build.VERSION.SDK_INT.toString(),
            reason = "Android API 版本",
            source = "Build.VERSION",
            now = now,
        )
        val hcppConfigured = applicationMetadataBoolean("io.flutter.embedding.android.EnableHcpp")
        rows += row(
            id = "platform.hcpp.manifest",
            state = when (hcppConfigured) {
                true -> CapabilityState.SUPPORTED
                false -> CapabilityState.UNSUPPORTED
                null -> CapabilityState.UNKNOWN
            },
            configured = hcppConfigured,
            reason = if (hcppConfigured == true) "应用 Manifest 已启用 HCPP" else "未能从 Manifest 确认 HCPP 配置",
            source = "PackageManager.applicationInfo.metaData",
            now = now,
        )
        rows += row(
            id = "webview.provider",
            state = if (web?.provider == null) CapabilityState.UNKNOWN else CapabilityState.SUPPORTED,
            observed = web?.provider,
            reason = "当前 WebView provider",
            source = "WebViewCompat.getCurrentWebViewPackage",
            now = now,
        )
        rows += row(
            id = "webview.isolatedScripts",
            state = stateFor(web?.enhanced),
            configured = true,
            effective = web?.enhanced,
            observed = web?.let { "world=${it.hasWorld};navigation=${it.hasNavigation}" },
            reason = if (web == null) "WebView 能力查询失败" else if (web.enhanced) "共享网页能力评估器确认隔离脚本链路可用" else "缺少隔离世界或导航监听能力，网页增强按 fail-closed 处理",
            source = "NativeWebCapabilityEvaluator",
            now = now,
            detailsJson = JSONObject()
                .put("world", web?.hasWorld ?: JSONObject.NULL)
                .put("navigation", web?.hasNavigation ?: JSONObject.NULL)
                .put("documentStart", web?.hasStart ?: JSONObject.NULL)
                .put("multiProfile", web?.hasProfiles ?: JSONObject.NULL)
                .toString(),
        )
        rows += row(
            id = "webview.documentStart",
            state = stateFor(web?.hasStart),
            effective = web?.hasStart,
            reason = "文档开始注入能力",
            source = "NativeWebCapabilityEvaluator",
            now = now,
        )
        rows += row(
            id = "webview.mediaControl",
            state = stateFor(web?.mediaControlSupported),
            configured = true,
            effective = web?.mediaControlSupported,
            reason = if (web == null) "WebView 能力查询失败" else if (web.mediaControlSupported) {
                "网页媒体识别与后台控制所需能力可用；实际播放由会话观测确认"
            } else "缺少原生静音、文档开始注入或消息监听能力，网页媒体识别与后台控制停用；更新系统 WebView 后重试",
            source = "NativeWebCapabilityEvaluator / BrowserMediaController",
            now = now,
            detailsJson = JSONObject()
                .put("muteAudio", web?.hasMuteAudio ?: JSONObject.NULL)
                .put("documentStart", web?.hasDocumentStartScript ?: JSONObject.NULL)
                .put("webMessageListener", web?.hasWebMessageListener ?: JSONObject.NULL)
                .toString(),
        )
        rows += row(
            id = "webview.privateProbes",
            state = stateFor(web?.hasProfiles),
            effective = web?.hasProfiles,
            reason = "独立 WebView Profile 能力",
            source = "NativeWebCapabilityEvaluator",
            now = now,
        )

        rows += guarded("permissions.runtime", now) { permissionRow(now) }
        rows += guarded("storage.saf.persistedGrants", now) { safRow(now) }
        rows += guarded("background.powerAndIdle", now) { backgroundRow(now) }
        rows += guarded("network.activeTransport", now) { networkRow(now) }
        rows += guarded("network.privateDns", now) { privateDnsRow(now) }
        rows += guarded("notifications.runtime", now) { notificationRow(now) }
        rows += guarded("background.workManager", now) { workManagerRow(now) }
        rows += guarded("platform.graphicsDeclarations", now) { graphicsRow(now) }
        rows += row("network.dlna.multicast", CapabilityState.UNKNOWN,
            "DLNA 接收器可达性未知；只读取既有多播锁，不发起 SSDP、SOAP 或网络探测", "MainActivity multicast lock / passive policy", now,
            detailsJson = JSONObject().put("multicastLockHeld", multicastLockHeld() ?: JSONObject.NULL).toString())
        rows += row("media.codecInventory", CapabilityState.SUPPORTED,
            "支持按需读取 MediaCodecList；声明不代表已成功解码", "MediaCodecList", now)
        rows += row("media.pipeline", CapabilityState.SUPPORTED,
            "播放沿用 ExoPlayer；导出与 Inspector 能力按已集成模块声明，实际成功由会话记录证明", "Application native wiring", now,
            configured = true,
            detailsJson = JSONObject().put("playback", "Media3 ExoPlayer")
                .put("metadataRetriever", classAvailable("androidx.media3.inspector.MetadataRetriever"))
                .put("frameExtractor", classAvailable("androidx.media3.inspector.frame.FrameExtractor"))
                .put("mediaExtractorCompat", classAvailable("androidx.media3.inspector.MediaExtractorCompat"))
                .put("transformer", classAvailable("androidx.media3.transformer.Transformer")).toString())
        rows += guarded("permissions.installPackages", now) {
            val granted = appContext.packageManager.canRequestPackageInstalls()
            row("permissions.installPackages", stateFor(granted),
                "只读取未知来源应用安装授权，不打开设置或请求权限", "PackageManager.canRequestPackageInstalls", now,
                effective = granted)
        }
        rows += NativeMediaObservations.snapshot()

        return DeviceDiagnosticsSnapshot(
            platform = "Android",
            osVersion = Build.VERSION.RELEASE ?: "unknown",
            apiLevel = Build.VERSION.SDK_INT.toLong(),
            appVersion = packageInfo.versionName ?: "unknown",
            flutterVersion = runCatching {
                appContext.packageManager.getApplicationInfo(appContext.packageName, PackageManager.GET_META_DATA)
                    .metaData?.getString("dev.vikiea.site_lens.FlutterVersion")
            }.getOrNull(),
            webViewProvider = web?.provider,
            capturedAtMs = now,
            capabilities = rows,
        )
    }

    private fun readCodecsNow(): List<CodecDescriptor> {
        val result = mutableListOf<CodecDescriptor>()
        val list = MediaCodecList(MediaCodecList.ALL_CODECS)
        for (info in list.codecInfos) {
            val hardware = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) runCatching { info.isHardwareAccelerated }.getOrNull() else null
            val software = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) runCatching { info.isSoftwareOnly }.getOrNull() else null
            for (mime in info.supportedTypes) {
                val profileQuery = runCatching {
                    val caps = info.getCapabilitiesForType(mime)
                    JSONArray().apply {
                        caps.profileLevels.forEach { profileLevel ->
                            put(JSONObject().put("profile", profileLevel.profile).put("level", profileLevel.level))
                        }
                    }.toString()
                }
                result += CodecDescriptor(
                    name = info.name,
                    mimeType = mime,
                    encoder = info.isEncoder,
                    hardwareAccelerated = hardware,
                    softwareOnly = software,
                    vendor = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) runCatching { info.isVendor.toString() }.getOrNull() else null,
                    profileLevelsJson = profileQuery.getOrNull(),
                    error = if (profileQuery.isFailure) "profile/level 查询失败" else null,
                )
            }
        }
        return result
    }

    private fun permissionRow(now: Long): CapabilityRecord {
        val requested = appContext.packageManager
            .getPackageInfo(appContext.packageName, PackageManager.GET_PERMISSIONS)
            .requestedPermissions
            .orEmpty()
            // REQUEST_INSTALL_PACKAGES is a special app-op queried through
            // canRequestPackageInstalls(). It is not a runtime permission and
            // must not make the ordinary permission row look denied.
            .filterNot { it == "android.permission.REQUEST_INSTALL_PACKAGES" }
        val statuses = JSONArray()
        var denied = 0
        var applicable = 0
        requested.forEach { permission ->
            val supported = isPermissionApplicable(permission, Build.VERSION.SDK_INT)
            val granted = if (supported) appContext.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED else null
            if (supported) applicable++
            if (granted == false) denied++
            statuses.put(JSONObject().put("permission", permission)
                .put("applicable", supported).put("granted", granted ?: JSONObject.NULL))
        }
        val canInstall = appContext.packageManager.canRequestPackageInstalls()
        return row(
            id = "permissions.runtime",
            state = if (denied == 0) CapabilityState.SUPPORTED else CapabilityState.UNSUPPORTED,
            configured = requested.isNotEmpty(),
            effective = denied == 0,
            observed = "$denied/$applicable denied",
            reason = "已合并 Manifest 权限和当前授权状态；拒绝状态不等于永久拒绝",
            source = "PackageManager.checkSelfPermission",
            now = now,
            detailsJson = JSONObject().put("permissions", statuses)
                .put("canInstallPackages", canInstall).toString(),
        )
    }

    private fun safRow(now: Long): CapabilityRecord {
        val grants = appContext.contentResolver.persistedUriPermissions
        val details = JSONArray().apply {
            grants.forEach { grant ->
                put(JSONObject().put("uri", grant.uri.toString())
                    .put("read", grant.isReadPermission).put("write", grant.isWritePermission)
                    .put("persistedAtMs", grant.persistedTime))
            }
        }
        return row(
            id = "storage.saf.persistedGrants",
            state = if (grants.isEmpty()) CapabilityState.UNKNOWN else CapabilityState.SUPPORTED,
            effective = grants.isNotEmpty(),
            observed = "${grants.size} persisted grants",
            reason = "仅读取 SAF 持久化授权；未验证 provider 当前可写性",
            source = "ContentResolver.persistedUriPermissions",
            now = now,
            detailsJson = details.toString(),
        )
    }

    private fun backgroundRow(now: Long): CapabilityRecord {
        val power = appContext.getSystemService(PowerManager::class.java)
        val details = JSONObject().put("powerSave", power?.isPowerSaveMode ?: JSONObject.NULL)
            .put("deviceIdle", power?.isDeviceIdleMode ?: JSONObject.NULL)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val activity = appContext.getSystemService(ActivityManager::class.java)
            details.put("backgroundRestricted", activity?.isBackgroundRestricted ?: JSONObject.NULL)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            details.put("ignoringBatteryOptimizations", power?.isIgnoringBatteryOptimizations(appContext.packageName) ?: JSONObject.NULL)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val usage = appContext.getSystemService(android.app.usage.UsageStatsManager::class.java)
            details.put("standbyBucket", usage?.appStandbyBucket ?: JSONObject.NULL)
        }
        return row(
            id = "background.powerAndIdle",
            state = CapabilityState.SUPPORTED,
            // This row reports the OS facts. Whether the app's background
            // policy is effective depends on the requested work and is shown
            // separately by the settings policy row.
            effective = null,
            observed = "状态已读取",
            reason = "省电、idle、优化豁免和 standby bucket 仅被动读取",
            source = "PowerManager/UsageStatsManager",
            now = now,
            detailsJson = details.toString(),
        )
    }

    private fun networkRow(now: Long): CapabilityRecord {
        val manager = appContext.getSystemService(ConnectivityManager::class.java)
        val network = manager?.activeNetwork
        val caps = network?.let { manager.getNetworkCapabilities(it) }
        val validated = caps?.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_VALIDATED)
        val metered = caps?.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_NOT_METERED)?.not()
        val transports = listOf(
            "wifi" to android.net.NetworkCapabilities.TRANSPORT_WIFI,
            "cellular" to android.net.NetworkCapabilities.TRANSPORT_CELLULAR,
            "ethernet" to android.net.NetworkCapabilities.TRANSPORT_ETHERNET,
            "vpn" to android.net.NetworkCapabilities.TRANSPORT_VPN,
        ).filter { caps?.hasTransport(it.second) == true }.map { it.first }
        return row(
            id = "network.activeTransport",
            state = if (network == null) CapabilityState.UNKNOWN else CapabilityState.SUPPORTED,
            effective = network != null,
            observed = when {
                network == null -> null
                validated == true -> "validated"
                else -> "connected-unvalidated"
            },
            reason = "只读取系统当前网络状态；Wi-Fi 不代表接收器可达",
            source = "ConnectivityManager",
            now = now,
            detailsJson = JSONObject().put("validated", validated ?: JSONObject.NULL)
                .put("metered", metered ?: JSONObject.NULL)
                .put("transports", JSONArray(transports)).toString(),
        )
    }

    private fun privateDnsRow(now: Long): CapabilityRecord {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) {
            return row("network.privateDns", CapabilityState.NOT_APPLICABLE,
                "Android API 28 以下无系统 Private DNS 状态接口", "Build.VERSION", now)
        }
        val manager = appContext.getSystemService(ConnectivityManager::class.java)
        val network = manager?.activeNetwork
        val links = network?.let { manager.getLinkProperties(it) }
        // Global settings are not readable on every Android version/vendor.
        // Preserve that uncertainty separately from the public network facts.
        val settings = runCatching {
            val resolver = appContext.contentResolver
            Settings.Global.getString(resolver, "private_dns_mode") to
                Settings.Global.getString(resolver, "private_dns_specifier")
        }
        val mode = settings.getOrNull()?.first
        val specifier = settings.getOrNull()?.second
        val active = links?.isPrivateDnsActive
        val provider = links?.privateDnsServerName
        return row(
            id = "network.privateDns",
            state = if (links == null) CapabilityState.UNKNOWN else CapabilityState.SUPPORTED,
            // A stored hostname is configuration, not proof of active DNS.
            configured = when (mode) {
                "hostname", "opportunistic" -> true
                "off" -> false
                else -> null
            },
            effective = active,
            observed = active?.let { if (it) "当前网络已启用 Private DNS" else "当前网络未启用 Private DNS" },
            reason = "只读取系统配置与当前网络状态；未查询域名，不证明目标域名可解析或可访问",
            source = "ConnectivityManager.getLinkProperties / Settings.Global",
            now = now,
            detailsJson = JSONObject()
                .put("configuredMode", mode ?: JSONObject.NULL)
                .put("configuredProvider", specifier ?: JSONObject.NULL)
                .put("configurationReadable", settings.isSuccess)
                .put("active", active ?: JSONObject.NULL)
                .put("networkProvider", provider ?: JSONObject.NULL)
                .toString(),
        )
    }

    private fun notificationRow(now: Long): CapabilityRecord {
        val manager = appContext.getSystemService(NotificationManager::class.java)
        val enabled = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) manager?.areNotificationsEnabled() else null
        val channels = manager?.notificationChannels
        return row(
            id = "notifications.runtime",
            state = when (enabled) {
                true -> CapabilityState.SUPPORTED
                false -> CapabilityState.UNSUPPORTED
                null -> CapabilityState.UNKNOWN
            },
            effective = enabled,
            observed = channels?.let { "${it.size} channels" },
            reason = "只读取通知授权和已有渠道",
            source = "NotificationManager",
            now = now,
            detailsJson = channels?.let { list ->
                JSONArray().apply { list.forEach {
                    put(JSONObject().put("id", it.id).put("importance", it.importance))
                } }.toString()
            },
        )
    }

    private fun workManagerRow(now: Long): CapabilityRecord {
        val infos = runCatching {
            WorkManager.getInstance(appContext)
                .getWorkInfosForUniqueWork("site-lens-health-check")
                .get(250, TimeUnit.MILLISECONDS)
        }.getOrNull()
        val observed = infos?.takeIf { it.isNotEmpty() }?.joinToString(",") { it.state.name }
        return row(
            id = "background.workManager",
            state = when {
                infos == null -> CapabilityState.UNKNOWN
                infos.isEmpty() -> CapabilityState.UNSUPPORTED
                else -> CapabilityState.SUPPORTED
            },
            effective = when {
                infos == null -> null
                infos.isEmpty() -> false
                else -> infos.any { !it.state.isFinished }
            },
            observed = observed ?: if (infos != null) "没有已调度任务" else null,
            reason = "只读取既有 WorkManager 状态；不创建、不更新、不取消任务",
            source = "WorkManager.getWorkInfosForUniqueWork",
            now = now,
        )
    }

    private fun applicationMetadataBoolean(name: String): Boolean? = runCatching {
        val info = appContext.packageManager.getApplicationInfo(
            appContext.packageName,
            PackageManager.GET_META_DATA,
        )
        if (info.metaData?.containsKey(name) != true) null else info.metaData?.getBoolean(name)
    }.getOrNull()

    private fun stateFor(value: Boolean?): CapabilityState = when (value) {
        true -> CapabilityState.SUPPORTED
        false -> CapabilityState.UNSUPPORTED
        null -> CapabilityState.ERROR
    }

    private fun classAvailable(name: String): Boolean = runCatching {
        Class.forName(name, false, appContext.classLoader)
        true
    }.getOrDefault(false)

    private fun guarded(id: String, now: Long, read: () -> CapabilityRecord): CapabilityRecord =
        runCatching(read).getOrElse {
            row(id, CapabilityState.ERROR, "系统只读查询失败；其他项目仍可查看", "Android passive query", now)
        }

    private fun graphicsRow(now: Long): CapabilityRecord {
        val features = appContext.packageManager.systemAvailableFeatures
        val vulkan = features.filter { it.name?.startsWith("android.hardware.vulkan") == true }
        val gles = features.firstOrNull { it.reqGlEsVersion != 0 }?.reqGlEsVersion
        return row("platform.graphicsDeclarations", CapabilityState.SUPPORTED,
            "系统声明的 Vulkan/GLES 能力；不代表当前 Flutter 渲染后端", "PackageManager.systemAvailableFeatures", now,
            detailsJson = JSONObject().put("glesVersion", gles ?: JSONObject.NULL)
                .put("vulkan", JSONArray().apply { vulkan.forEach {
                    put(JSONObject().put("feature", it.name).put("version", it.version))
                } }).toString())
    }

    private fun row(
        id: String,
        state: CapabilityState,
        reason: String,
        source: String,
        now: Long,
        configured: Boolean? = null,
        effective: Boolean? = null,
        observed: String? = null,
        detailsJson: String? = null,
    ) = CapabilityRecord(
        id = id,
        state = state,
        configured = configured,
        effective = effective,
        observed = observed,
        reason = reason,
        source = source,
        capturedAtMs = now,
        detailsJson = detailsJson,
    )
}

internal fun isPermissionApplicable(permission: String, sdkInt: Int): Boolean = when (permission) {
    "android.permission.POST_NOTIFICATIONS" -> sdkInt >= 33
    "android.permission.FOREGROUND_SERVICE" -> sdkInt >= 28
    "android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK" -> sdkInt >= 34
    else -> true
}
