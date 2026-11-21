package dev.vikiea.site_lens

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.net.wifi.WifiManager
import android.provider.Settings
import androidx.core.content.FileProvider
import androidx.webkit.ProfileStore
import androidx.webkit.WebViewFeature
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterShellArgs
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private companion object {
        const val FORMAL_CERT_SHA256 = "9db2d0302374a13f915382c06dbbcee315cca82e04d073eaa10a5de9e752947d"
    }
    private var hosts: NativeWebHostRegistry? = null
    private var pendingNotification: Pair<String, String>? = null
    private var notificationPermissionAsked = false
    private var nativeMedia: NativeMediaRuntime? = null
    private var siteCredentials: SiteCredentialChannel? = null
    private var appRuntime: NativeAppRuntime? = null
    private var nativeDownloads: NativeDownloadRuntime? = null
    private var mediaNetworkRuntime: MediaNetworkRuntime? = null
    private var nativeExport: NativeExportRuntime? = null
    private var nativeUpdate: NativeUpdateRuntime? = null
    private var nativeSystemNetwork: NativeSystemNetworkRuntime? = null
    private var deviceDiagnostics: NativeDeviceDiagnostics? = null
    private var dlnaMulticastLock: WifiManager.MulticastLock? = null
    private var diagnosticsExecutor: ExecutorService? = null
    private var diagnosticsGeneration = 0
    private var authRefreshGeneration = 0

    override fun getFlutterShellArgs(): FlutterShellArgs =
        FlutterRendererPolicy.shellArgs(
            super.getFlutterShellArgs().toArray(),
        )

    private fun postNotification(title: String, body: String) {
        val manager = getSystemService(NotificationManager::class.java)
        val channelId = "site-lens-health"
        manager.createNotificationChannel(
            NotificationChannel(
                channelId,
                "站点存活检查",
                NotificationManager.IMPORTANCE_DEFAULT,
            ),
        )
        val notification = Notification.Builder(this, channelId)
            .setContentTitle(title)
            .setContentText(body)
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setAutoCancel(true)
            .build()
        manager.notify(9000, notification)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != 4711) return
        val granted =
            grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
        val pending = pendingNotification
        pendingNotification = null
        if (granted && pending != null) postNotification(pending.first, pending.second)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (nativeExport?.handleActivityResult(requestCode, resultCode, data) == true) return
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        nativeUpdate?.handleIntent(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        if (WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE)) {
            val store = ProfileStore.getInstance()
            for (name in store.allProfileNames.filter { it.startsWith("site-lens-probe-") }) {
                try { store.deleteProfile(name) } catch (_: IllegalStateException) { }
            }
        }
        hosts = NativeWebHostRegistry(this, flutterEngine)
        appRuntime = NativeAppRuntime(this, requireNotNull(hosts))
        AppRuntimeApi.setUp(flutterEngine.dartExecutor.binaryMessenger, appRuntime)
        deviceDiagnostics = NativeDeviceDiagnostics(this) { dlnaMulticastLock?.isHeld ?: false }
        DeviceDiagnosticsApi.setUp(flutterEngine.dartExecutor.binaryMessenger, deviceDiagnostics)
        registerDiagnosticsChannel(flutterEngine)
        registerDeviceChannel(flutterEngine)
        registerUpdateChannel(flutterEngine)
        registerSiteCredentialChannel(flutterEngine)
        registerNativeMediaChannel(flutterEngine)
        registerMediaAuthChannel(flutterEngine)
        registerNativeDownloadChannel(flutterEngine)
        registerSystemNetworkChannel(flutterEngine)
        registerNativeExportChannel(flutterEngine)
        registerDlnaChannel(flutterEngine)
    }

    private fun registerDiagnosticsChannel(flutterEngine: FlutterEngine) {
        diagnosticsExecutor?.shutdownNow()
        val executor = Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "site-lens-diagnostics").apply { isDaemon = true }
        }
        diagnosticsExecutor = executor
        val generation = ++diagnosticsGeneration
        val mainHandler = Handler(Looper.getMainLooper())
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "site_lens/diagnostics",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "ack" -> try {
                    val rows = call.argument<List<String>>("rows").orEmpty()
                    executor.execute {
                        val acknowledged = runCatching { NativeCrashStore.acknowledge(applicationContext, rows) }
                        mainHandler.post {
                            if (generation != diagnosticsGeneration) return@post
                            runCatching { acknowledged.fold(
                                onSuccess = { result.success(null) },
                                onFailure = { result.error("diagnostics_unavailable", it.message, null) },
                            ) }
                        }
                    }
                } catch (error: RuntimeException) {
                    if (generation == diagnosticsGeneration) runCatching {
                        result.error("diagnostics_unavailable", error.message, null)
                    }
                }
                "drain" -> try {
                    executor.execute {
                        val drained = runCatching {
                            NativeCrashStore.drainIncludingHistoricalExits(applicationContext)
                        }
                        mainHandler.post {
                            if (generation == diagnosticsGeneration) {
                                runCatching { drained.fold(
                                    onSuccess = { rows -> result.success(rows) },
                                    onFailure = { error -> result.error("diagnostics_unavailable", error.message, null) },
                                ) }
                            }
                        }
                    }
                } catch (error: RuntimeException) {
                    if (generation == diagnosticsGeneration) runCatching {
                        result.error("diagnostics_unavailable", error.message, null)
                    }
                }
                else -> if (generation == diagnosticsGeneration) runCatching { result.notImplemented() }.let { }
            }
        }
    }

    private fun registerDeviceChannel(flutterEngine: FlutterEngine) {
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "site_lens/device",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "isCharging" -> {
                    val battery = getSystemService(Context.BATTERY_SERVICE) as BatteryManager
                    result.success(battery.isCharging)
                }
                "notify" -> {
                    val title = call.argument<String>("title") ?: "择站 · Site Lens"
                    val body = call.argument<String>("body") ?: ""
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                        checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) !=
                            PackageManager.PERMISSION_GRANTED
                    ) {
                        pendingNotification = title to body
                        if (!notificationPermissionAsked) {
                            notificationPermissionAsked = true
                            requestPermissions(
                                arrayOf(android.Manifest.permission.POST_NOTIFICATIONS),
                                4711,
                            )
                        }
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    postNotification(title, body)
                    result.success(true)
                }
                "prepareNotifications" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                        checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) !=
                            PackageManager.PERMISSION_GRANTED
                    ) {
                        if (!notificationPermissionAsked) {
                            notificationPermissionAsked = true
                            requestPermissions(
                                arrayOf(android.Manifest.permission.POST_NOTIFICATIONS),
                                4711,
                            )
                        }
                        result.success(false)
                    } else {
                        result.success(true)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun registerUpdateChannel(flutterEngine: FlutterEngine) {
        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "site_lens/update",
        )
        nativeUpdate?.dispose()
        nativeUpdate = NativeUpdateRuntime(this).also { it.attach(channel) }
        nativeUpdate?.handleIntent(intent)
        channel.setMethodCallHandler { call, result ->
            if (nativeUpdate?.handle(call, result) == true) return@setMethodCallHandler
            when (call.method) {
                "canInstallPackages" -> result.success(canInstallPackages())
                "openInstallPermissionSettings" -> {
                    openInstallPermissionSettings()
                    result.success(null)
                }
                "verifyApk", "verifyAndInstallApk" -> {
                    val path = call.argument<String>("path")
                    val expectedSha256 = call.argument<String>("sha256")
                    val expectedVersion = call.argument<String>("version")
                    if (path.isNullOrBlank() || expectedSha256.isNullOrBlank() || expectedVersion.isNullOrBlank()) {
                        result.error("invalid_apk", "APK 校验参数不完整", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val apk = verifyDownloadedApk(File(path), expectedSha256, expectedVersion)
                        if (call.method == "verifyAndInstallApk") installApk(apk)
                        result.success(null)
                    } catch (error: UpdateInstallException) {
                        result.error(error.code, error.message, null)
                    } catch (error: Exception) {
                        result.error("install_failed", error.message ?: "APK 校验或安装失败", null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * 站点凭证通道（ADR-0007）：`push` / `clear` 写，`has` 只回答有没有。没有
     * `get`：凭证值不回传给应用侧。
     */
    private fun registerSiteCredentialChannel(flutterEngine: FlutterEngine) {
        val store = SiteCredentialPreferencesStore(this)
        val credentials = SiteCredentialChannel(
            shelf = SiteCredentialRecord.Shelf(),
            clock = { System.currentTimeMillis() },
            loader = { reader ->
                for (profileId in store.profileIds()) {
                    store.read(profileId)?.let { reader.accept(profileId, it) }
                }
            },
        ).also { it.restore() }
        siteCredentials = credentials
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "site_lens/credentials")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "push" -> {
                        val profileId = call.argument<Number>("profileId")?.toInt()
                        val record = call.argument<String>("credential")
                        if (profileId == null || profileId < 0 || record == null) {
                            result.error("invalid_credential", "站点凭证参数不完整", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val receipt = credentials.push(profileId, record)
                            store.write(profileId, record)
                            result.success(receipt)
                        } catch (error: IllegalArgumentException) {
                            // 拒绝不覆盖：应用侧那一份不动，原生侧也保持原样。
                            result.error("invalid_credential", error.message, null)
                        }
                    }
                    "clear" -> {
                        val profileId = call.argument<Number>("profileId")?.toInt()
                        if (profileId == null || profileId < 0) {
                            result.error("invalid_credential", "站点档案无效", null)
                            return@setMethodCallHandler
                        }
                        store.delete(profileId)
                        result.success(credentials.clear(profileId))
                    }
                    "has" -> {
                        val profileId = call.argument<Number>("profileId")?.toInt() ?: -1
                        result.success(
                            mapOf("profileId" to profileId, "has" to credentials.has(profileId)),
                        )
                    }
                    "epoch" -> result.success(mapOf("epoch" to credentials.epoch))
                    else -> result.notImplemented()
                }
            }
    }

    private fun registerNativeMediaChannel(flutterEngine: FlutterEngine) {
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "site_lens/native_media")
        val credentials = siteCredentials ?: SiteCredentialChannel(
            shelf = SiteCredentialRecord.Shelf(),
            clock = { System.currentTimeMillis() },
        )
        nativeMedia = NativeMediaRuntime(this, flutterEngine.renderer, credentials)
            .also { it.attach(channel) }
    }

    private fun registerMediaAuthChannel(flutterEngine: FlutterEngine) {
        val generation = ++authRefreshGeneration
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "site_lens/media_auth")
            .setMethodCallHandler { call, result ->
                if (generation != authRefreshGeneration) return@setMethodCallHandler
                when (call.method) {
                    "refresh" -> refreshOne(generation, call, result)
                    "refreshBatch" -> refreshBatch(generation, call, result)
                    else -> result.notImplemented()
                }
            }
    }

    private fun refreshOne(
        generation: Int,
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        val request = authRefreshRequest(call)
        if (request == null) {
            result.error("invalid_auth_refresh", "授权刷新参数不完整", null)
            return
        }
        NativeMediaAuthRefreshService.refresh(
            applicationContext,
            request.copy(callback = { value ->
                if (generation == authRefreshGeneration) {
                    result.success(value)
                } else {
                    result.error(
                        "engine_replaced",
                        "Flutter 引擎已替换，授权刷新已取消",
                        null,
                    )
                }
            }),
        )
    }

    /**
     * One service lifetime per page origin, one page load per page URL.
     *
     * An incomplete entry fails the whole call: a partially understood batch
     * would bind some tasks to an address nobody verified.
     */
    private fun refreshBatch(
        generation: Int,
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        val raw = call.argument<List<Map<String, Any?>>>("requests").orEmpty()
        val requests = ArrayList<NativeMediaAuthRefreshService.Request>(raw.size)
        for (entry in raw) {
            val request = authRefreshRequest(entry)
            if (request == null) {
                result.error("invalid_auth_refresh", "授权刷新参数不完整", null)
                return
            }
            requests.add(request)
        }
        if (requests.isEmpty()) {
            result.error("invalid_auth_refresh", "授权刷新参数不完整", null)
            return
        }
        NativeMediaAuthRefreshService.refreshBatch(applicationContext, requests) { values ->
            if (generation == authRefreshGeneration) {
                result.success(mapOf("results" to values))
            } else {
                result.error(
                    "engine_replaced",
                    "Flutter 引擎已替换，授权刷新已取消",
                    null,
                )
            }
        }
    }

    /**
     * The one place a single refresh argument map is read.
     *
     * Both channel shapes (a method-call map and one entry of a batch list)
     * carry exactly the same fields, so they share this reader: a field added
     * later cannot be understood by one path and silently dropped by the other.
     */
    private fun authRefreshRequest(call: MethodCall): NativeMediaAuthRefreshService.Request? =
        authRefreshRequest(call.arguments as? Map<*, *>)

    private fun authRefreshRequest(args: Map<*, *>?): NativeMediaAuthRefreshService.Request? {
        if (args == null) return null
        val taskId = args.authRefreshField("taskId").orEmpty()
        return authRefreshRequest(
            taskId = taskId,
            pageUrl = args.authRefreshField("pageUrl").orEmpty(),
            mediaUrl = args.authRefreshField("mediaUrl").orEmpty(),
            resourceKey = args.authRefreshField("resourceKey").orEmpty(),
            logicalIdentity = args.authRefreshField("logicalIdentity")
                ?: zeroWidthLogicalIdentity(taskId),
        )
    }

    /** One trimmed string field, or `null` when it is absent or not a string. */
    private fun Map<*, *>.authRefreshField(key: String): String? =
        (this[key] as? String)?.trim()

    private fun authRefreshRequest(
        taskId: String,
        pageUrl: String,
        mediaUrl: String,
        resourceKey: String,
        logicalIdentity: String,
    ): NativeMediaAuthRefreshService.Request? {
        if (taskId.isEmpty() || pageUrl.isEmpty() || mediaUrl.isEmpty()) return null
        return NativeMediaAuthRefreshService.Request(
            taskId = taskId,
            pageUrl = pageUrl,
            mediaUrl = mediaUrl,
            resourceKey = resourceKey,
            logicalIdentity = logicalIdentity,
        ) { _ -> }
    }

    /**
     * A caller that omits the logical identity keeps the old single-request
     * behaviour: its own task id is the identity, so it can only adopt the
     * capture of its own load.
     */
    private fun zeroWidthLogicalIdentity(taskId: String): String = "task:$taskId"

    private fun registerNativeDownloadChannel(flutterEngine: FlutterEngine) {
        mediaNetworkRuntime?.dispose()
        val mediaNetworkChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "site_lens/media_network")
        mediaNetworkRuntime = MediaNetworkRuntime(this, mediaNetworkChannel).also {
            mediaNetworkChannel.setMethodCallHandler(it)
        }
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "site_lens/native_download")
        nativeDownloads = NativeDownloadRuntime(this).also { channel.setMethodCallHandler(it) }
    }

    private fun registerSystemNetworkChannel(flutterEngine: FlutterEngine) {
        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "site_lens/system_network",
        )
        nativeSystemNetwork?.dispose()
        nativeSystemNetwork = NativeSystemNetworkRuntime(this).also {
            channel.setMethodCallHandler(it)
        }
    }

    private fun registerNativeExportChannel(flutterEngine: FlutterEngine) {
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "site_lens/native_export")
        nativeExport = NativeExportRuntime(this).also {
            it.attach(channel)
            channel.setMethodCallHandler(it)
        }
    }

    private fun registerDlnaChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "site_lens/dlna")
            .setMethodCallHandler { call, result ->
                val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                when (call.method) {
                    "acquireMulticastLock" -> {
                        if (dlnaMulticastLock == null) {
                            dlnaMulticastLock = wifi.createMulticastLock("site-lens-dlna").apply {
                                setReferenceCounted(false)
                                acquire()
                            }
                        } else if (dlnaMulticastLock?.isHeld != true) {
                            dlnaMulticastLock?.acquire()
                        }
                        result.success(null)
                    }
                    "releaseMulticastLock" -> {
                        dlnaMulticastLock?.takeIf { it.isHeld }?.release()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun canInstallPackages(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O || packageManager.canRequestPackageInstalls()

    private fun openInstallPermissionSettings() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        startActivity(
            Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:$packageName"),
            ),
        )
    }

    private fun verifyDownloadedApk(apk: File, expectedSha256: String, expectedVersion: String): File {
        if (!apk.isFile) throw UpdateInstallException("invalid_apk", "下载的 APK 不存在")
        if (!expectedSha256.matches(Regex("[0-9a-fA-F]{64}"))) {
            throw UpdateInstallException("invalid_apk", "APK SHA-256 校验值格式错误")
        }
        if (!sha256(apk).equals(expectedSha256, ignoreCase = true)) {
            throw UpdateInstallException("digest_mismatch", "APK SHA-256 校验失败")
        }
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            @Suppress("DEPRECATION") PackageManager.GET_SIGNATURES
        }
        val archive = packageManager.getPackageArchiveInfo(apk.absolutePath, flags)
            ?: throw UpdateInstallException("invalid_apk", "无法读取下载的 APK")
        if (archive.packageName != packageName) {
            throw UpdateInstallException("package_mismatch", "下载的 APK 不是 Site Lens 正式包")
        }
        if (archive.versionName != expectedVersion) {
            throw UpdateInstallException("version_mismatch", "APK 版本与发布信息不一致")
        }
        val current = packageManager.getPackageInfo(packageName, flags)
        val currentCertificates = certificateDigests(current)
        val archiveCertificates = certificateDigests(archive)
        if (currentCertificates != setOf(FORMAL_CERT_SHA256) ||
            archiveCertificates != setOf(FORMAL_CERT_SHA256) ||
            currentCertificates != archiveCertificates
        ) {
            throw UpdateInstallException("signature_mismatch", "下载的 APK 不是 Site Lens 正式签名")
        }
        val currentCode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) current.longVersionCode else @Suppress("DEPRECATION") current.versionCode.toLong()
        val archiveCode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) archive.longVersionCode else @Suppress("DEPRECATION") archive.versionCode.toLong()
        if (archiveCode <= currentCode) {
            throw UpdateInstallException("version_not_newer", "下载的 APK 版本号没有高于当前版本")
        }
        return apk
    }

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { byte -> "%02x".format(byte) }
    }

    private fun installApk(apk: File) {
        if (!canInstallPackages()) {
            throw UpdateInstallException("install_permission_required", "请先允许安装未知来源应用")
        }
        val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", apk)
        startActivity(
            Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            },
        )
    }

    private fun certificateDigests(info: PackageInfo): Set<String> {
        val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val signingInfo = info.signingInfo ?: return emptySet()
            if (signingInfo.hasMultipleSigners()) signingInfo.apkContentsSigners
            else signingInfo.signingCertificateHistory
        } else {
            @Suppress("DEPRECATION") info.signatures
        }
        if (signatures.isNullOrEmpty()) return emptySet()
        return signatures.mapTo(mutableSetOf()) { signature ->
            MessageDigest.getInstance("SHA-256").digest(signature.toByteArray())
                .joinToString("") { byte -> "%02x".format(byte) }
        }
    }

    override fun onPause() { hosts?.foreground(false); super.onPause() }
    override fun onResume() { super.onResume(); hosts?.foreground(true) }
    override fun onStop() { hosts?.foreground(false); super.onStop() }
    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        diagnosticsGeneration++
        authRefreshGeneration++
        diagnosticsExecutor?.shutdownNow()
        diagnosticsExecutor = null
        AppRuntimeApi.setUp(flutterEngine.dartExecutor.binaryMessenger, null)
        appRuntime?.dispose()
        appRuntime = null
        DeviceDiagnosticsApi.setUp(flutterEngine.dartExecutor.binaryMessenger, null)
        deviceDiagnostics?.dispose()
        deviceDiagnostics = null
        hosts?.dispose(); hosts = null
        nativeMedia?.dispose(); nativeMedia = null
        nativeDownloads?.dispose(); nativeDownloads = null
        mediaNetworkRuntime?.dispose(); mediaNetworkRuntime = null
        nativeExport?.dispose(); nativeExport = null
        nativeUpdate?.dispose(); nativeUpdate = null
        nativeSystemNetwork?.dispose(); nativeSystemNetwork = null
        dlnaMulticastLock?.takeIf { it.isHeld }?.release()
        dlnaMulticastLock = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    private class UpdateInstallException(val code: String, message: String) : Exception(message)
}
