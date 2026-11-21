#!/usr/bin/env python3
"""Read-only source contracts for WebView media ownership and frame control."""

from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
ANDROID = ROOT / "android/app/src/main/kotlin/dev/vikiea/site_lens"
CONTROLLER = (ANDROID / "BrowserMediaController.kt").read_text()
HOST = (ANDROID / "NativeWebHost.kt").read_text()
SERVICE = (ANDROID / "BrowserMediaService.kt").read_text()
LIFECYCLE = (ROOT / "web_assets/media_lifecycle.js").read_text()
TRANSFER = (ANDROID / "ResumableMediaTransfer.kt").read_text()
DOWNLOAD_RUNTIME = (ANDROID / "NativeDownloadRuntime.kt").read_text()
DOWNLOAD_WORKER = (ANDROID / "NativeMediaDownloadWorker.kt").read_text()
NATIVE_MEDIA = (ANDROID / "NativeMediaRuntime.kt").read_text()
NATIVE_SESSION = (ANDROID / "NativeMediaSessionService.kt").read_text()
NATIVE_DART = (ROOT / "lib/media/native_media_runtime.dart").read_text()
AUTH_REFRESH = (ANDROID / "NativeMediaAuthRefreshService.kt").read_text()
MAIN_ACTIVITY = (ANDROID / "MainActivity.kt").read_text()
POLICY = (ANDROID / "MediaAuthRefreshPolicy.kt").read_text()
NATIVE_EXPORT = (ANDROID / "NativeExportRuntime.kt").read_text()
NATIVE_LEASES = (ANDROID / "NativeMediaFileLeases.kt").read_text()
CREDENTIAL_DATA_SOURCE = (ANDROID / "SiteCredentialDataSource.kt").read_text()
CREDENTIAL_RECORD = (ANDROID / "SiteCredentialRecord.kt").read_text()
AUTHORED_HTTP = (ANDROID / "AuthoredHttpRequest.kt").read_text()
CREDENTIAL_REOPEN = (ROOT / "lib/media/credential_reopen.dart").read_text()
CREDENTIAL_HANDOFF = (ROOT / "lib/media/site_credential_handoff.dart").read_text()
APP_CONTROLLER = (ROOT / "lib/ui/app_controller.dart").read_text()
NATIVE_CACHE = (ANDROID / "NativeMediaPlaybackCache.kt").read_text()
CACHE_POLICY = (ANDROID / "NativeMediaPlaybackCachePolicy.kt").read_text()
CACHE_ADR = (ROOT / "docs/adr/0010-remote-playback-cache-is-separate-from-downloads.md").read_text()
DATA_MANAGEMENT = (ROOT / "lib/ui/data_management_screen.dart").read_text()
NATIVE_LIBRARY = (ROOT / "lib/media/native_download_runtime.dart").read_text()

# REGRESSION CONTRACT: MEDIA-HLS-001


class NativeMediaContractTests(unittest.TestCase):
    def test_native_playback_file_lease_contract_is_fail_closed(self):
        self.assertIn('class MediaFileLeaseRegistry', NATIVE_LEASES)
        for token in ('acquireRead', 'acquireMutation', 'overlaps', 'taskIds', 'documents'):
            self.assertIn(token, NATIVE_LEASES)
        local = NATIVE_MEDIA.split('private fun openLocal(', 1)[1].split('private fun openInService(', 1)[0]
        self.assertIn('openInService(', local)
        self.assertLess(local.index('openFileDescriptor'), local.index('openInService'))
        self.assertIn('Uri.fromFile(file).toString()', local)
        # 租约范围由判定对象给出；服务只负责拿与放。
        route = (ANDROID / "NativeMediaSessionRoute.kt").read_text()
        self.assertIn('MediaFileLeaseRegistry.Scope.file(parent)', route)
        self.assertEqual(1, NATIVE_SESSION.count('NativeMediaFileLeases.registry.acquireRead('))
        self.assertLess(
            NATIVE_SESSION.index('acquireRead(it)'),
            NATIVE_SESSION.index('player.setMediaItem'),
        )
        # 进程内播放器与它的文件租约都不存在了；租约只由服务持有与释放。
        self.assertNotIn('fileLease', NATIVE_MEDIA)
        self.assertNotIn('ExoPlayer.Builder', NATIVE_MEDIA)
        self.assertIn('fileLease?.close()', NATIVE_SESSION)
        self.assertIn('var fileLease: Closeable? = null', NATIVE_SESSION)

    def test_native_media_session_service_owns_background_player_and_media3_notification(self):
        self.assertIn('class NativeMediaSessionService : MediaSessionService()', NATIVE_SESSION)
        for token in (
            'MediaSession.Builder(this, player)',
            'override fun onGetSession',
            'DefaultMediaNotificationProvider.Builder(applicationContext)',
            '.setNotificationId(ID)',
            '.setChannelId(CHANNEL)',
            'setMediaNotificationProvider(notificationProvider)',
            'addSession(mediaSession)',
            'if (isSessionAdded(mediaSession)) removeSession(mediaSession)',
            'SHOW_NOTIFICATION_FOR_IDLE_PLAYER_ALWAYS',
            'setHandleAudioBecomingNoisy(true)',
            'private var userPaused = false',
            'userPaused -> "paused"',
            'fileLease?.close()',
            '"backend" to "media_session"',
        ):
            self.assertIn(token, NATIVE_SESSION)
        self.assertNotIn('媒体播放准备中', NATIVE_SESSION)

    def test_native_network_recovery_requeues_workers_without_pre_route_dns(self):
        runtime = (ANDROID / "NativeDownloadRuntime.kt").read_text()
        worker = (ANDROID / "NativeMediaDownloadWorker.kt").read_text()
        media_network = (ANDROID / "MediaNetworkRuntime.kt").read_text()
        self.assertIn('"networkChanged" -> networkChanged()', runtime)
        self.assertIn('cancelWorkById(workId)', runtime)
        self.assertIn('enqueue(record)', runtime)
        self.assertIn('ownedTransfer?.abort()', worker)
        self.assertIn('partial plus resume', runtime)
        # The worker and the foreground runtime must hand every hop to the
        # route-aware connection helper instead of resolving a target first.
        # The helper gained a trailing Fake-IP fallback argument; the contract
        # is the call itself, not its exact argument list.
        self.assertIn('SystemMediaNetwork.openMediaConnection(', worker)
        self.assertIn('applicationContext, uri, attempt', worker)
        self.assertIn('SystemMediaNetwork.openMediaConnection(', media_network)
        self.assertIn('context, uri, attempt', media_network)
        self.assertNotIn('hasDirectRoute(uri)', worker)
        self.assertNotIn('hasDirectRoute(uri)', media_network)
        self.assertIn('NativeMediaSessionService.detachSurface(context)', NATIVE_MEDIA)
        self.assertIn('serviceSessionId = null', NATIVE_MEDIA)
        for token in (
            'data class PendingAction',
            'cancel: () -> Unit',
            'action.cancel()',
            'pending.removeFirst()',
            'pending.isEmpty()',
            'instance === service',
        ):
            self.assertIn(token, NATIVE_SESSION)

    def test_remote_sessions_are_decided_by_one_route_object(self):
        route = (ANDROID / "NativeMediaSessionRoute.kt").read_text()
        # 判定对象必须能独立单测：不引入 Android 类，也不碰 Media3。
        for forbidden in ("android.", "androidx.", "Context", "Uri.parse"):
            self.assertNotIn(forbidden, route)
        for token in (
            "internal data class NativeMediaSessionRoute",
            "enum class Family",
            "LOCAL",
            "REMOTE",
            "holdsFileLease",
            "isRestorable",
            "fun leaseForOpening(",
            "fun sourceOf(",
            "fun shouldPreserveRestorable(",
            "fun shouldRestore(",
            "Scheme.HTTP",
            "Scheme.HTTPS",
        ):
            self.assertIn(token, route)
        # 服务只按判定对象的结论执行：租约、可恢复记录、冷恢复、数据源四处。
        self.assertIn("NativeMediaSessionRoute.classify(", NATIVE_SESSION)
        self.assertIn("val leaseScope = route.leaseForOpening(", NATIVE_SESSION)
        self.assertIn("val nextLease = leaseScope?.let { NativeMediaFileLeases.registry.acquireRead(it) }", NATIVE_SESSION)
        self.assertIn("if (route.isRestorable) clearRestorable()", NATIVE_SESSION)
        self.assertIn("when (route.sourceOf(hls))", NATIVE_SESSION)
        self.assertIn("private fun sessionAllowsRestorable(): Boolean", NATIVE_SESSION)
        self.assertIn("restorable = sessionAllowsRestorable()", NATIVE_SESSION)
        self.assertIn("NativeMediaSessionRoute.shouldRestore(uri)", NATIVE_SESSION)
        self.assertIn("NativeMediaSessionRoute.shouldPreserveRestorable(raw)", NATIVE_SESSION)
        self.assertNotIn('require(uri.scheme == "file" || uri.scheme == "content")', NATIVE_SESSION)

    def test_remote_admission_is_a_site_credential_not_a_preference(self):
        # ADR-0009: `media_access/remoteSourceAllowed` 已退休；远程来源的准入门槛
        # 是站点凭证，公开内容没有凭证也照播。
        for name in (
            "PREF_REMOTE_SOURCE_ALLOWED",
            "remoteSourceAllowed",
            "preferenceAllowsRemoteSource",
        ):
            self.assertNotIn(name, NATIVE_MEDIA)
            self.assertNotIn(name, (ANDROID / "NativeMediaSessionRoute.kt").read_text())
            self.assertNotIn(name, NATIVE_SESSION)
        self.assertIn("hasCredential = credentials.remoteSourceEnabled(profileId, raw)", NATIVE_MEDIA)
        self.assertIn("hasCredential = headersFor(request).isNotEmpty()", NATIVE_SESSION)
        self.assertIn("fun admit(", (ANDROID / "NativeMediaSessionRoute.kt").read_text())

    def test_fragments_and_cdn_requests_carry_the_credential_per_request(self):
        # T6：分片与 CDN 请求也带凭证。判定按**每一次请求的地址**重新做，不是
        # 一次性的会话头；头合并只在 AuthoredHttpRequest 一处发生。
        for token in (
            "fun withCredentialHeaders(",
            "headersFor(dataSpec.uri.toString())",
            "AuthoredHttpRequest.merge(",
            "dataSpec.withAdditionalHeaders(merged)",
        ):
            self.assertIn(token, CREDENTIAL_DATA_SOURCE)
        # 数据来源不缓存、不记忆上一次的头。
        for forbidden in ("remember", "cached", "lastHeaders"):
            self.assertNotIn(forbidden, CREDENTIAL_DATA_SOURCE)
        for token in (
            "fun merge(",
            "SiteCredentialRecord.HEADER_AUTHORIZATION",
            "SiteCredentialRecord.HEADER_COOKIE",
            "ignoreCase = true",
        ):
            self.assertIn(token, AUTHORED_HTTP)
        # 只有凭证那两个头会被改写；其余的头保持页面原样。
        self.assertNotIn("putAll(", AUTHORED_HTTP)
        # 主清单与分片走同一个数据来源：HLS 与渐进式各自挂同一个工厂。
        self.assertEqual(
            2,
            NATIVE_SESSION.count("remoteDataSources(request)"),
        )
        self.assertEqual(
            1,
            NATIVE_SESSION.count("SiteCredentialDataSource.factory { url -> headersFor(request, url) }"),
        )
        self.assertIn("HlsMediaSource.Factory(", NATIVE_SESSION)
        self.assertIn("ProgressiveMediaSource.Factory(", NATIVE_SESSION)
        # 本地文件路径不经过这个数据来源。
        local = NATIVE_SESSION.split("SourceKind.LOCAL_GROWING_FILE ->", 1)[1].split(
            "SourceKind.REMOTE_HTTP ->", 1
        )[0]
        self.assertNotIn("SiteCredentialDataSource", local)
        self.assertIn("GrowingFileDataSource.Factory()", local)

    def test_credentials_cross_into_native_through_a_one_way_channel(self):
        channel = (ANDROID / "SiteCredentialChannel.kt").read_text()
        activity = (ANDROID / "MainActivity.kt").read_text()
        for token in (
            'site_lens/credentials',
            '"push" ->',
            '"clear" ->',
            '"has" ->',
            '"epoch" ->',
            "credentials.push(profileId, record)",
            "store.write(profileId, record)",
        ):
            self.assertIn(token, activity)
        for forbidden in ('"get"', '"read" ->', '"credential" ->', "fun dump"):
            self.assertNotIn(forbidden, activity.split("registerSiteCredentialChannel", 1)[1].split(
                "private fun registerNativeMediaChannel", 1
            )[0])
        # 原生侧没有把凭证值打回去的入口：读取面只有「有没有」。
        self.assertNotIn("fun get(", channel)
        self.assertNotIn("fun credential(", channel)
        self.assertNotIn("fun value(", channel)
        self.assertIn("fun push(", channel)
        self.assertIn("fun clear(", channel)
        self.assertIn("fun has(", channel)

    def test_remote_requests_carry_the_token_and_the_cookie_jar(self):
        source = (ANDROID / "SiteCredentialDataSource.kt").read_text()
        session = NATIVE_SESSION
        for token in (
            "class SiteCredentialDataSource",
            "withCredentialHeaders(",
            "HEADER_AUTHORIZATION",
            "HEADER_COOKIE",
        ):
            self.assertIn(token, source)
        for token in (
            "HlsMediaSource.Factory(",
            "ProgressiveMediaSource.Factory(",
            "SiteCredentialDataSource.factory { url -> headersFor(request, url) }",
        ):
            self.assertIn(token, session)
        # 凭证只进请求：会话快照、事件与日志里都不能出现令牌或 cookie 值。
        snapshot = session.split("private fun snapshot()", 1)[1].split("private fun persistCurrentState", 1)[0]
        for forbidden in ("accessToken", "cookies", "Authorization", "Cookie"):
            self.assertNotIn(forbidden, snapshot)

    def test_401_and_403_are_credential_rejections_with_a_bounded_retry(self):
        policy = (ANDROID / "SiteCredentialFailurePolicy.kt").read_text()
        for token in (
            "401, 403 -> Disposition(Kind.CREDENTIAL_REJECTED)",
            "const val MAX_RETRIES = 1",
            "fun mayRetry(attempt: Int): Boolean = attempt in 1..MAX_RETRIES",
            "EVENT_CREDENTIAL_REJECTED",
        ):
            self.assertIn(token, policy)
        # 网络失败与内容不可用各是各的结论，不并进凭证失效。
        self.assertIn("fun networkFailure()", policy)
        self.assertIn("else -> Disposition(Kind.CONTENT_UNAVAILABLE)", policy)
        for token in (
            "ERROR_CODE_IO_BAD_HTTP_STATUS",
            "HttpDataSource.InvalidResponseCodeException",
            "SiteCredentialFailurePolicy.EVENT_CREDENTIAL_REJECTED",
            "awaitCredentialThenRetry(",
            "onCredentialPushed(",
        ):
            self.assertIn(token, NATIVE_SESSION)

    def test_a_recovered_credential_reopens_the_episode_once(self):
        # T6：续期成功后播放器自动重开本集，用户不需要手动重试。
        for token in (
            "class CredentialReopenPlanner",
            "enum ReopenStatus",
            "ReopenStatus.needsLogin",
            "ReopenStatus.exhausted",
            "int reopensFor(String sessionId)",
            "void forget(String sessionId)",
        ):
            self.assertIn(token, CREDENTIAL_REOPEN)
        # 去重按会话：同一段会话只重开一次，终止性拒绝不重开。
        self.assertIn("if (event.terminal)", CREDENTIAL_REOPEN)
        self.assertIn("if (used > 0)", CREDENTIAL_REOPEN)
        # 续期链把重开接进来，但「需要重新登录」的结论不受影响。
        for token in (
            "final void Function()? reopen;",
            "final reopenPlanner = CredentialReopenPlanner();",
            "void _planReopen(NativeCredentialEvent event)",
            "reopenPlanner.plan(event: event, reopen: reopen)",
        ):
            self.assertIn(token, CREDENTIAL_HANDOFF)
        # 重开失败不改写续期成功的结论。
        self.assertIn("reopenPlanner.forget(event.sessionId)", CREDENTIAL_HANDOFF)
        # 应用侧记住这一次远程打开用的参数，重开的是同一集。
        for token in (
            "Future<void> reopenAfterCredentialRefresh()",
            "reopen: () => unawaited(reopenAfterCredentialRefresh()),",
            "MediaCandidate candidate,\n    int hostId,\n    int generation,\n    Uri sourceUrl,\n    int? profileId,",
        ):
            self.assertIn(token, APP_CONTROLLER)

    def test_credential_files_never_log_a_value(self):
        for name in (
            "SiteCredentialRecord.kt",
            "SiteCredentialChannel.kt",
            "SiteCredentialDataSource.kt",
            "SiteCredentialStore.kt",
            "SiteCredentialFailurePolicy.kt",
        ):
            source = (ANDROID / name).read_text()
            self.assertNotIn("Log.", source)
            self.assertNotIn("println(", source)
            self.assertNotIn("printStackTrace", source)

    def test_process_local_remote_player_is_no_longer_a_path(self):
        for token in (
            "private fun start(",
            "startAfterStop",
            "referer",
            "SystemMediaNetwork.buildOkHttpClient(",
            "AndroidCookieReader.get(",
        ):
            self.assertNotIn(token, NATIVE_MEDIA)
        # 远程地址唯一出口是媒体会话，进程内不再自建 ExoPlayer 播放它。
        # T7 之后这一次调用额外带缓存准入，调用形态由花括号参数列表给出。
        self.assertIn("openInService(", NATIVE_MEDIA)
        remote_open = NATIVE_MEDIA.split("private fun open(call: MethodCall", 1)[1].split(
            "private fun playbackCacheAdmission", 1
        )[0]
        self.assertIn('taskId = ""', remote_open)
        self.assertIn("admitsPlaybackCache = admitted", remote_open)
        self.assertNotIn("ExoPlayer.Builder", remote_open)

    def test_local_service_replacement_does_not_stop_the_service(self):
        self.assertIn('stopLocalPlayer()', NATIVE_MEDIA)
        replacement = NATIVE_MEDIA.split('private fun openInService(', 1)[1].split(
            'private fun openInServiceAfterStop(', 1
        )[0]
        self.assertNotIn('NativeMediaSessionService.stop(context)', replacement)
        self.assertIn('openRequestId++', replacement)
        self.assertIn('requestId != openRequestId', NATIVE_MEDIA)
        self.assertIn('serviceSessionId = null', NATIVE_MEDIA)

    def test_replacement_open_survives_service_release_but_explicit_stop_cancels(self):
        for token in (
            'retryOnRelease = true',
            'explicitStopInProgress',
            'markExplicitStop()',
            'requeuePending(',
            'shouldRequeueAfterRelease',
            'instance == null && pending.isNotEmpty()',
            'val retryOnRelease: Boolean',
            'action.retryOnRelease',
            'val isCurrent: () -> Boolean = { true }',
            'check(request.isCurrent())',
        ):
            self.assertIn(token, NATIVE_SESSION)

    def test_native_media_service_enters_foreground_before_media3_setup(self):
        on_create = NATIVE_SESSION.split('override fun onCreate()', 1)[1].split(
            'private fun installPlayerListener', 1
        )[0]
        self.assertLess(
            on_create.index('startForegroundImmediately()'),
            on_create.index('DefaultMediaNotificationProvider.Builder'),
        )
        for token in (
            'startForeground(ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)',
            '原生媒体会话',
            'NotificationCompat.Builder(this, CHANNEL)',
            'super.onStartCommand(intent, flags, startId)',
        ):
            self.assertIn(token, NATIVE_SESSION)

    def test_native_download_retry_budget_is_persisted_and_non_retryable_tls_stops(self):
        for token in (
            'const val MAX_NETWORK_ATTEMPTS = 8',
            'retryIfBudgetAllows',
            'transferAttempts < MAX_NETWORK_ATTEMPTS',
            'runAttemptCount < MAX_NETWORK_ATTEMPTS',
            'error.retryable()',
            'TLS 证书或主机名校验失败，已停止重试',
        ):
            self.assertIn(token, DOWNLOAD_WORKER)
        self.assertNotIn('} else if (runAttemptCount < 1) Result.retry()', DOWNLOAD_WORKER)

    def test_dart_open_is_invalidated_by_stop_and_dispose(self):
        for token in (
            'int _openGeneration = 0',
            'int _beginOpen() => ++_openGeneration',
            "throw StateError('原生媒体请求已过期')",
            'final requestGeneration = _beginOpen()',
            '_ensureOpenCurrent(requestGeneration)',
            '_openGeneration++;',
        ):
            self.assertIn(token, NATIVE_DART)

    def test_native_media_session_persists_recoverable_state_without_autoplay(self):
        for token in (
            'native_media_session_state',
            'persistCurrentState()',
            'readRestorable()',
            '"restorable" to (sessionId == null && restorable != null)',
            'if (restorable != null) state = "restorable"',
            'clearRestorable()',
            'POSITION_PERSISTENCE_MS = 2_000L',
            'startPositionPersistence()',
            'stopPositionPersistence()',
            'positionHandler.postDelayed(this, POSITION_PERSISTENCE_MS)',
            '"userPaused" to if (sessionId != null) userPaused else restorable?.userPaused ?: true',
            'val autoPlay: Boolean = true',
        ):
            self.assertIn(token, NATIVE_SESSION)
        self.assertIn('fun hasRestorableState(context: Context)', NATIVE_SESSION)
        self.assertIn('raw["restorable"] == true', NATIVE_MEDIA)
        on_create = NATIVE_SESSION.split('override fun onCreate()', 1)[1].split('override fun onGetSession', 1)[0]
        self.assertNotIn('player.setMediaItem', on_create)
        self.assertNotIn('player.prepare()', on_create)

    def test_partial_hls_uses_bounded_growing_file_reads(self):
        source = (ANDROID / "GrowingFileDataSource.kt").read_text()
        for token in (
            'class GrowingFileDataSource',
            'awaitCommitted(file, dataSpec.position)',
            'DEFAULT_WAIT_TIMEOUT_MS = 15_000L',
            'Thread.sleep(POLL_INTERVAL_MS)',
            'file.length() > position',
            'GrowingFileDataSource.Factory()',
        ):
            self.assertTrue(token in source or token in NATIVE_SESSION, token)

    def test_background_authorization_refresh_is_same_origin_and_fail_closed(self):
        self.assertIn('class NativeMediaAuthRefreshService : Service()', AUTH_REFRESH)
        for token in (
            'view.settings.javaScriptEnabled = true',
            'override fun shouldOverrideUrlLoading',
            'override fun onPageStarted',
            'onCreateWindow',
            'setSupportMultipleWindows(false)',
            '"waiting_execution"',
            '"reauthorize"',
            'CookieManager.getInstance().getCookie',
            'put("cookieDigest", digest)',
            'startForeground(ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)',
            'requests',
            'activeRequest',
            'pendingLock',
            'postedRequests',
            'activeToken',
            'private fun startNext()',
            'if (activeRequest != null || requests.isEmpty()) return',
            'private fun postRequest(request: Request)',
            'if (token != activeToken || finished) return',
        ):
            self.assertIn(token, AUTH_REFRESH)
        self.assertNotIn('evaluateJavascript', AUTH_REFRESH)
        self.assertNotIn('addJavascriptInterface', AUTH_REFRESH)
        self.assertIn('NativeMediaAuthRefreshService.refreshBlocking', (ANDROID / 'NativeMediaDownloadWorker.kt').read_text())

    def test_background_authorization_refresh_captures_the_pages_own_playlist(self):
        # The refresh adopts the address the page itself requests, and the
        # decision logic lives in the pure policy object.
        self.assertIn('override fun shouldInterceptRequest', AUTH_REFRESH)
        for token in (
            'MediaAuthRefreshPolicy.isMainPlaylist',
            'MediaAuthRefreshPolicy.classify',
            'MediaAuthRefreshPolicy.finishBatch',
            'MediaAuthRefreshPolicy.groupByOrigin',
            'MediaAuthRefreshPolicy.distinctPageUrls',
            'MediaAuthRefreshPolicy.captureDigest',
            'MediaAuthRefreshPolicy.hasUnknownQuery',
        ):
            self.assertIn(token, AUTH_REFRESH)
        # A capture lands on the main handler; the shared list is not touched
        # from the WebView background thread.
        capture = AUTH_REFRESH.split('override fun shouldInterceptRequest', 1)[1].split(
            'override fun shouldOverrideUrlLoading', 1)[0]
        self.assertIn('main.post {', capture)
        self.assertIn('sessionCaptures', AUTH_REFRESH)
        # The address is returned to the caller under its own key.
        self.assertIn('put("mediaUrl", mediaUrl)', AUTH_REFRESH)
        self.assertIn('put("logicalIdentity", request.logicalIdentity)', AUTH_REFRESH)
        # A play address is not on the page's site, so neither the capture nor
        # the page load may be gated on origin: redirects and cross-site
        # manifests are normal.
        self.assertNotIn('页面尝试跨站跳转', AUTH_REFRESH)
        self.assertNotIn('授权页面来源已变化', AUTH_REFRESH)
        self.assertIn('if (request.isForMainFrame) return super.shouldInterceptRequest(view, request)', AUTH_REFRESH)
        self.assertNotIn('isSameSessionOrigin(pageOrigin, raw)', AUTH_REFRESH)
        # The query allowlist moved into the policy object and is never a gate.
        self.assertIn('fun hasUnknownQuery(url: String): Boolean', POLICY)
        self.assertNotIn('NON_AUTH_MEDIA_QUERY_KEYS', AUTH_REFRESH)
        # The old pre-flight that blocked the page load is gone.
        self.assertNotIn('requiresUrlReauthorization', AUTH_REFRESH)
        self.assertNotIn('result("reauthorize", "媒体地址需要播放页重新授权")', AUTH_REFRESH)
        # A cookie change is no longer a success on its own.
        self.assertIn('pageSettled = true', AUTH_REFRESH)
        self.assertNotIn('refreshedResult(request, pageOrigin, mediaOrigin, cookie, digest)', AUTH_REFRESH)
        # A capture ends the wait; a blocked wait is bounded at 8 s.
        self.assertIn('BLOCKING_WAIT_MS = 8_000L', AUTH_REFRESH)
        self.assertIn('latch.await(BLOCKING_WAIT_MS, TimeUnit.MILLISECONDS)', AUTH_REFRESH)
        self.assertNotIn('TIMEOUT_MS + 2_000L', AUTH_REFRESH)
        # One service lifetime per page origin, one navigation per page URL.
        self.assertIn('fun refreshBatch(', AUTH_REFRESH)

    def test_background_authorization_refresh_never_logs_a_media_address(self):
        # No Log. call site may interpolate a URL-bearing variable; log lines
        # carry the policy digest instead.
        log_lines = [line.strip() for line in AUTH_REFRESH.splitlines() if 'Log.' in line]
        self.assertTrue(log_lines, 'expected at least one log line to guard')
        forbidden = re.compile(r'\$\{?(mediaUrl|url|capturedUrl|pageUrl|raw|next)\b')
        for line in log_lines:
            self.assertIsNone(
                forbidden.search(line),
                'log line interpolates a URL: ' + line,
            )

    def test_batch_channel_answers_every_request_once(self):
        for token in (
            '"refreshBatch"',
            'NativeMediaAuthRefreshService.refreshBatch',
            '"invalid_auth_refresh"',
            'logicalIdentity',
        ):
            self.assertIn(token, MAIN_ACTIVITY)

    def test_media_transfer_diagnostics_expose_only_cookie_presence(self):
        self.assertIn('val cookiePresent: Boolean', TRANSFER)
        self.assertIn('"cookiePresent" to cookiePresent', TRANSFER)
        self.assertIn('cookiePresent = cookiePresent', TRANSFER)
        self.assertNotIn('"Cookie" to cookie', TRANSFER)

    def test_native_mutations_take_file_leases_before_cancellation_or_delete(self):
        download = (ANDROID / "NativeDownloadRuntime.kt").read_text()
        export = NATIVE_EXPORT
        self.assertIn('NativeMediaFileLeases.registry.mutate(scope)', download)
        self.assertIn('reserveMutation', download)
        self.assertIn('mutationReservations', download)
        for token in (
            'ownsMutationReservation',
            'fun dispose()',
        ):
            self.assertIn(token, download)
        self.assertNotIn('"migrateLegacyDirectories"', download)
        delete = download.split(
            'private fun delete(taskId: String, reservationId: String? = null)', 1
        )[1].split('private fun validTaskId(', 1)[0]
        self.assertLess(delete.index('registry.mutate(scope)'), delete.index('stop(taskId, true'))
        self.assertLess(delete.index('deleteUnderLease'), delete.index('NativeMediaDownloadWorker.files'))
        normal_export = export.split('} else {', 1)[1]
        self.assertLess(
            normal_export.index('registry.mutate(mutationScope(call))'),
            normal_export.index('execute(call, cancellation)'),
        )
        scope = export.split('private fun mutationScope(', 1)[1].split('private fun execute(', 1)[0]
        for operation in ('"delete"', '"move"', '"rename"', '"deliver"', '"materialize"', '"deleteOwnedSources"', '"copyVerified"'):
            self.assertIn(operation, scope)

    def test_group_cleanup_takes_one_native_reservation_and_preserves_partial_progress(self):
        scope = NATIVE_EXPORT.split('private fun mutationScope(', 1)[1].split('private fun execute(', 1)[0]
        self.assertIn('ownedSources(call).fold(MediaFileLeaseRegistry.Scope.task(taskId))', scope)
        body = NATIVE_EXPORT.split('private fun deleteOwnedSources(', 1)[1].split('private fun fail(', 1)[0]
        self.assertLess(body.index('sources.forEach'), body.index('delete(source, allowMissing = true)'))
        self.assertIn('PartialMediaDeletion(deleted.toList(), error)', body)
        library = (ROOT / 'lib/media/media_library.dart').read_text()
        self.assertIn('native!.deleteOwnedSources(', library)
        self.assertIn('mutationReservationId: nativeMutationReservation', library)
        self.assertIn("details['deletedSources']", library)

    def test_verified_local_copy_and_move_stay_under_native_reservations(self):
        copy = NATIVE_EXPORT.split('private fun copyVerified(', 1)[1].split('private fun deliverToDirectory(', 1)[0]
        self.assertIn('registry.acquireRead(MediaFileLeaseRegistry.Scope.source(source))', copy)
        self.assertIn('sourceMutationHeld', copy)
        for token in ('temporary.canonicalFile == temporary', '!temporary.exists()',
                      '!target.exists()', 'actual.digest().contentEquals(expected.digest())',
                      'temporary.renameTo(target)', 'finally { if (temporary.exists()) temporary.delete() }'):
            self.assertIn(token, copy)
        execute = NATIVE_EXPORT.split('private fun execute(', 1)[1].split('private fun ownedSources(', 1)[0]
        self.assertIn('sourceMutationHeld = true', execute)
        self.assertNotIn('runCatching { delete(source) }', execute)
        self.assertIn('registry.acquireRead(readScope(call)).use', NATIVE_EXPORT)
        move = NATIVE_EXPORT.split('"move" -> {', 1)[1].split('"delete" ->', 1)[0]
        self.assertIn('completeMediaMove(target, { delete(source) }, { delete(target, allowMissing = true) })', move)
        self.assertIn('"recoveryTarget" to error.target', NATIVE_EXPORT)

    def test_directory_delivery_reuses_verified_same_size_documents(self):
        delivery = NATIVE_EXPORT.split(
            'private fun deliverToDirectory(', 1
        )[1].split('private fun checkDirectory(', 1)[0]
        for token in (
            'reuseExistingIfSameSize: Boolean = false',
            'val existing = findChildDocument(tree, targetParentId, fileName)',
            'existing.size == File(sourcePath).length()',
            'return existing.uri.toString()',
            'DocumentsContract.createDocument',
        ):
            self.assertIn(token, delivery)
        post_lookup = delivery.split(
            'val existing = findChildDocument(tree, targetParentId, fileName)',
            1,
        )[1]
        self.assertLess(
            post_lookup.index('existing.size == File(sourcePath).length()'),
            post_lookup.index('DocumentsContract.createDocument'),
        )

    def test_navigation_preparation_retires_previous_completion_and_page(self):
        host = (ANDROID / "NativeWebHost.kt").read_text()
        # A can complete while B is awaiting Dart's script/filter reply.
        # Retire A before the asynchronous preparation, so A cannot consume
        # B's entry/history state or publish committed(A) with B's generation.
        for start, end in (("fun prepareNavigation(", "private fun prepareHistoryNavigation("),
                           ("private fun prepareHistoryNavigation(", "val targetUrl =")):
            preparation = host.split(start, 1)[1].split(end, 1)[0]
            for retired in ("activeNavigation = null", "activePage = null", "sslNavigation = null"):
                self.assertLess(preparation.index(retired), preparation.index("revoke();"))
        completed = host.split("override fun onNavigationCompleted(", 1)[1].split(
            "override fun onPageDeleted(", 1)[0]
        self.assertLess(completed.index("if (activeNavigation != navigation) return"),
                        completed.index("clearHistoryNavigation()"))

    def test_retired_main_frame_errors_cannot_revoke_the_new_document(self):
        host = (ANDROID / "NativeWebHost.kt").read_text()
        for start, end in (("override fun onReceivedError(", "override fun onReceivedHttpError("),
                           ("override fun onReceivedHttpError(", "override fun onRenderProcessGone(")):
            body = host.split(start, 1)[1].split(end, 1)[0]
            guard = "request.isForMainFrame && sslFailures.affectsDocument(request.url.toString(), sslNavigation?.url)"
            self.assertLess(body.index(guard), body.index("revoke()"))

    def test_prepared_navigation_rejects_retired_ssl_redirect_callbacks(self):
        host = (ANDROID / "NativeWebHost.kt").read_text()
        # A is still active while B prepares. A's delayed redirect must not
        # reinsert A into B's SSL identities or publish A's URL over B's.
        for start, end in (("fun prepareNavigation(", "private fun prepareHistoryNavigation("),
                           ("private fun prepareHistoryNavigation(", "val targetUrl =")):
            preparation = host.split(start, 1)[1].split(end, 1)[0]
            self.assertLess(preparation.index("sslNavigation = null"),
                            preparation.index("sslFailures.navigate(url)"))
        redirect = host.split("override fun onNavigationRedirected(", 1)[1].split(
            "override fun onNavigationCompleted(", 1)[0]
        guard = "if (activeNavigation != navigation || sslNavigation !== navigation) return"
        self.assertLess(redirect.index(guard), redirect.index("sslFailures.redirected("))
        self.assertLess(redirect.index(guard), redirect.index('event("redirected"'))
        ssl_error = host.split("override fun onReceivedSslError(", 1)[1].split(
            "override fun onReceivedError(", 1)[0]
        self.assertLess(ssl_error.index("handler.cancel()"),
                        ssl_error.index("sslFailures.affectsDocument("))
        self.assertNotIn("handler.proceed()", ssl_error)

    def test_controller_uses_per_frame_reply_proxy_and_document_epoch(self):
        self.assertIn("JavaScriptReplyProxy", CONTROLLER)
        self.assertIn("frame.proxy.postMessage", CONTROLLER)
        self.assertIn("documentToken", CONTROLLER)
        self.assertIn("ownerToken", CONTROLLER)
        self.assertIn("activeDocument", CONTROLLER)
        self.assertIn("pendingFrames", CONTROLLER)
        self.assertIn("promotePending", CONTROLLER)
        self.assertIn("promoted.forEach", CONTROLLER)
        self.assertIn("epoch", CONTROLLER)
        self.assertIn("retired", CONTROLLER)
        self.assertIn("existing.proxy !== proxy", CONTROLLER)

    def test_media_candidate_bridge_preserves_episode_representation_identity(self):
        for token in (
            '"seriesKey" to if (candidate.has("seriesKey")) candidate.optString("seriesKey") else null',
            '"episodeNumber" to if (candidate.has("episodeNumber")) candidate.optInt("episodeNumber") else null',
            '"representationRank" to if (candidate.has("representationRank")) candidate.optInt("representationRank") else null',
            '"qualityLabel" to if (candidate.has("qualityLabel")) candidate.optString("qualityLabel") else null',
            '"audioLabel" to if (candidate.has("audioLabel")) candidate.optString("audioLabel") else null',
        ):
            self.assertIn(token, CONTROLLER)

    def test_page_owned_episode_resolution_is_same_origin_and_bounded(self):
        for token in (
            'function readEpisodeLinks()',
            'function episodePageSource(',
            "credentials: 'same-origin'",
            'finalUrl.origin !== current.origin',
            'AbortController',
            'episodePageActive < 2',
            'request.visit !== seriesVisit',
            'episodePageQueue = []',
        ):
            self.assertIn(token, LIFECYCLE)
        self.assertNotIn('http.request2', LIFECYCLE)

    def test_controller_publishes_foreground_owner_before_background(self):
        self.assertIn("if (!allowed) { stopService(); return }", CONTROLLER)
        self.assertIn("BrowserMediaService.update(", CONTROLLER)
        self.assertNotIn("if (!allowed || !background)", CONTROLLER)
        self.assertIn("if (run) view.onResume() else view.onPause()", CONTROLLER)

    def test_service_rejects_stale_owner_and_pending_intent_data(self):
        self.assertIn('intent?.getStringExtra("owner") != next.token', SERVICE)
        self.assertIn("intent.data?.host != next.token", SERVICE)
        self.assertIn("owner?.takeIf { it.token == token }", SERVICE)
        self.assertIn("if (!owns(token)) return", SERVICE)

    def test_javascript_accepts_only_current_frame_commands(self):
        self.assertIn("data.token !== config.token", LIFECYCLE)
        self.assertIn("data.frame !== frameId", LIFECYCLE)
        self.assertIn("data.command <= commandSequence", LIFECYCLE)
        self.assertIn("post('ack'", LIFECYCLE)
        self.assertIn("pagehide", LIFECYCLE)
        self.assertNotIn("post('gone')", LIFECYCLE.split("window.addEventListener('pagehide'", 1)[1].split("});", 1)[0])
        self.assertIn("site-lens-media-frame-gone", LIFECYCLE)
        self.assertIn('childFrame', CONTROLLER)
        self.assertIn('childParentFrame', LIFECYCLE)
        self.assertIn('parentFrame', CONTROLLER)
        self.assertIn('isDescendant', CONTROLLER)

    def test_javascript_splits_candidate_telemetry(self):
        self.assertIn("post('state', state)", LIFECYCLE)
        self.assertIn("post('candidates'", LIFECYCLE)
        self.assertIn("evidence:", LIFECYCLE)
        self.assertIn('mediaPlaybackEvidence', HOST)
        self.assertIn('"kind" to "playbackEvidence"', CONTROLLER)
        self.assertIn("raw.length <= 4096", LIFECYCLE)

    def test_media_snapshot_carries_frame_and_previous_page_identity(self):
        self.assertIn('previousPageUrl', LIFECYCLE)
        self.assertIn('"frame" to id', CONTROLLER)
        self.assertIn('"document" to document', CONTROLLER)
        self.assertIn('"main" to main', CONTROLLER)

    def test_native_transfer_keeps_range_validator_and_partial_bytes(self):
        self.assertIn('setRequestProperty("Range", "bytes=$offset-")', TRANSFER)
        self.assertIn('setRequestProperty("If-Range", validator)', TRANSFER)
        self.assertIn('Content-Range', TRANSFER)
        self.assertIn('RandomAccessFile(partial, "rw")', TRANSFER)
        self.assertIn('partial.length()', TRANSFER)
        self.assertIn('publishIfActive', TRANSFER)

    def test_native_transfer_never_discards_bytes_the_server_can_confirm(self):
        # Bytes on disk are kept and offered as a Range: a 206 or a 416 that
        # proves the file is complete confirms them, and a 200 rewrites them.
        # Neither a missing validator nor a rotated signature may force a
        # restart from zero, which is what made every retry re-download.
        self.assertNotIn('媒体分段响应缺少验证标识', TRANSFER)
        self.assertNotIn('媒体响应验证标识缺失或已变化', TRANSFER)
        self.assertIn('媒体响应 Range 无效', TRANSFER)
        self.assertIn('if (offset > 0 && total == offset) return offset', TRANSFER)

    def test_native_playback_claims_media_audio_focus(self):
        # 进程内播放器不再是播放路径，音频焦点只由媒体会话持有。
        self.assertIn("setAudioAttributes", NATIVE_SESSION)
        self.assertIn("C.USAGE_MEDIA", NATIVE_SESSION)
        self.assertIn("setHandleAudioBecomingNoisy(true)", NATIVE_SESSION)

    def test_hls_transformer_preflight_and_output_contract(self):
        body = NATIVE_EXPORT.split("private fun muxHls(", 1)[1].split("private fun validateSampleParity(", 1)[0]
        guards = (
            "val prepared = segments.mapIndexed", "Media3ExportValidation.mergeInputSegments",
            'tracks.containsKey("video")', "audioSegments == prepared.size",
            "validateSampleParity(inputSamples, outputSamples)",
            "track.pts.size == inputCounts[kind]", "validateOutput(temp.path, inputCounts)",
            "CONVERSION_PROCESS_TRANSMUXED", "audioEncoderName == null", "videoEncoderName == null",
        )
        for guard in guards:
            self.assertTrue(guard in body, f"Missing export guard: {guard}")
        self.assertLess(body.index("readSamples("), body.index("transformHls("))
        self.assertLess(body.index("validateSampleParity("), body.index("temp.renameTo(output)"))
        for legacy in ("Mp4Muxer.Builder", "muxer.writeSampleData", "MediaExtractor()"):
            self.assertFalse(legacy in body, f"Legacy sample writer remains: {legacy}")
        self.assertTrue("暂不支持含 discontinuity 的 HLS 清单导出" in NATIVE_EXPORT)

    def test_transformer_rejects_encoders_and_settles_cancel_after_release(self):
        body = NATIVE_EXPORT.split("private fun transformHls(", 1)[1].split("private fun writeTransformerPlaylist(", 1)[0]
        for name in ("createForAudioEncoding", "createForVideoEncoding"):
            method = body.split(f"override fun {name}", 1)[1].split("\n", 2)[1]
            self.assertTrue("throw ExportException" in method, f"{name} must reject creation")
        for token in ("HandlerThread(", ".setLooper(thread.looper)", "DefaultMuxer.Factory()",
                      "HlsMediaSource.Factory(localDataSources(allowed))", "terminal.compareAndSet(false, true)"):
            self.assertTrue(token in body, f"Missing Transformer lifecycle constraint: {token}")
        cancel = body.split("if (!terminal.get())", 1)[1]
        self.assertLess(cancel.index("transformer?.cancel()"), cancel.index("finish(error ="))
        self.assertTrue("settled.await(50, TimeUnit.MILLISECONDS)" in body)

    def test_export_data_sources_have_no_network_or_path_escape(self):
        body = NATIVE_EXPORT.split("private fun localDataSources(", 1)[1].split("private fun transformHls(", 1)[0]
        for guard in ('uri.scheme == "file"', "uri.authority.isNullOrEmpty()", "uri.query == null",
                      "uri.fragment == null", ".canonicalFile", "file.path in allowed", "isAppLocal(file)"):
            self.assertTrue(guard in body, f"Missing local resource guard: {guard}")
        for source in ("DefaultDataSource", "HttpDataSource"):
            self.assertFalse(source in body, f"Network-capable fallback: {source}")
        resources = NATIVE_EXPORT.split("private fun localResource(", 1)[1].split("private fun attribute(", 1)[0]
        self.assertTrue("allowedRoots.any" in resources,
                        "HLS resources must stay inside an explicitly allowed root")
        self.assertIn("nativeValidatePath(file.path, it.canonicalPath)", resources)
        playlist = NATIVE_EXPORT.split("private fun writeTransformerPlaylist(", 1)[1].split("private fun mediaTrackKind(", 1)[0]
        for token in ("METHOD=AES-128", "METHOD=NONE", "#EXT-X-MAP", "#EXT-X-ENDLIST"):
            self.assertTrue(token in playlist, f"Normalized playlist omits {token}")

    def test_inspection_uses_media3_and_bounds_sample_reports(self):
        for platform in ("android.media.MediaMetadataRetriever", "android.media.MediaExtractor", "ExoPlayer.Builder"):
            self.assertFalse(platform in NATIVE_EXPORT, f"Unexpected platform/player API: {platform}")
        for token in ("MetadataRetriever.Builder", "FrameExtractor.Builder", "reader.getThumbnail()",
                      "MediaExtractorCompat(", '"presentationTimesUs"', '"sampleSizes"', '"hasAdtsHeader"',
                      "MAX_MEDIA_SAMPLES = 2_000_000", "REPORTED_SAMPLES = 512"):
            self.assertTrue(token in NATIVE_EXPORT, f"Missing Inspector contract: {token}")
        fail = NATIVE_EXPORT.split("private fun fail(", 1)[1].split("fun dispose()", 1)[0]
        self.assertFalse("stackTraceToString" in fail, "Provider stack may expose private paths")

    def test_legacy_migration_can_recover_a_staged_copy(self):
        self.assertIn('stagedFinal = File(finalTarget.path + ".legacy.tmp")', DOWNLOAD_RUNTIME)
        self.assertIn('stagedPartial = File(partialTarget.path + ".legacy.tmp")', DOWNLOAD_RUNTIME)
        self.assertIn('commitLegacyCopy(stagedFinal, finalTarget)', DOWNLOAD_RUNTIME)
        self.assertIn('commitLegacyCopy(stagedPartial, partialTarget)', DOWNLOAD_RUNTIME)
        self.assertIn('private fun commitLegacyCopy', DOWNLOAD_RUNTIME)
        self.assertIn('if (staged.exists()) runCatching { staged.delete() }', DOWNLOAD_RUNTIME)

    def test_missing_saf_documents_map_to_a_specific_media_error(self):
        errors = (ANDROID / "MediaFileErrors.kt").read_text()
        self.assertIn('"media_file_missing"', errors)
        self.assertIn('"missing file"', errors)
        self.assertIn("SecurityException", errors)

    def test_profile_cleanup_deletes_profile_without_loaded_provider_access(self):
        host = (ANDROID / "NativeWebHost.kt").read_text()
        start = host.index("private fun clearProbeProfile")
        end = host.index("fun dispose()", start)
        body = host[start:end]
        self.assertIn("deleteProfile(name)", body)
        self.assertNotIn("getProfile", body)
        self.assertNotIn("cookieManager", body)
        self.assertNotIn("webStorage", body)

    def test_profile_cleanup_runs_after_webview_teardown(self):
        host = (ANDROID / "NativeWebHost.kt").read_text()
        normal = host[host.index("fun dispose()", host.index("class NativeWebHost(")):]
        normal = normal[:normal.index("\n    }\n}")]
        self.assertLess(normal.index("webView.destroy()"), normal.index("mainHandler.post { clearProbeProfile() }"))
        dead = host[host.index("private fun disposeAfterRendererGone"):]
        dead = dead[:dead.index("private fun clearProbeProfile")]
        self.assertLess(dead.index("deadView.destroy()"), dead.index("clearProbeProfile()"))

    def test_engine_detach_cleanup_is_nonblocking_and_drops_old_engine_callbacks(self):
        download_dispose = DOWNLOAD_RUNTIME.split("fun dispose()", 1)[1].split("companion object", 1)[0]
        export_dispose = NATIVE_EXPORT.split("fun dispose()", 1)[1].split("private fun pickDirectory", 1)[0]
        self.assertNotIn(".result.get", download_dispose)
        self.assertNotIn("awaitTermination", export_dispose)
        self.assertNotIn("pendingDirectoryResult?.error", export_dispose)

        download_call = DOWNLOAD_RUNTIME.split("override fun onMethodCall", 1)[1].split("private fun start", 1)[0]
        self.assertIn("if (disposed) return@execute", download_call)
        self.assertIn("if (disposed) return@post", download_call)

        export_call = NATIVE_EXPORT.split("override fun onMethodCall", 1)[1].split("private fun readScope", 1)[0]
        self.assertIn("if (!disposed) result.success(value)", export_call)
        self.assertIn("if (!disposed) fail(call, result, error)", export_call)

        cleanup = DOWNLOAD_RUNTIME.split("executor.execute {", 2)[2].split("companion object", 1)[0]
        self.assertLess(cleanup.index("val cleaned"), cleanup.index("cancelUniqueWork"))
        self.assertLess(cleanup.index("cancelUniqueWork"), cleanup.index("withFileLock"))
        self.assertLess(cleanup.index("withFileLock"), cleanup.index("if (cleaned &&"))
        self.assertIn("if (cleaned && mutationReservations.remove(id, reservation))", cleanup)


# REGRESSION CONTRACT: MEDIA-CACHE-002


class RemotePlaybackCacheContractTests(unittest.TestCase):
    """T7：远程播放缓存与下载分账，缓存有上限、可清除，且不切本地文件。"""

    def test_remote_sources_pass_through_the_cache_outside_credentials(self):
        section = NATIVE_SESSION.split("private fun remoteDataSources(", 1)[1]
        section = section.split("private fun headersFor", 1)[0]
        self.assertIn("SiteCredentialDataSource.factory", section)
        self.assertIn("NativeMediaPlaybackCache.dataSourceFactory(applicationContext, credentialed)", section)
        # 缓存包在凭证来源外面：命中缓存的分片不再取凭证、不再发请求。
        self.assertLess(
            section.index("SiteCredentialDataSource.factory"),
            section.index("NativeMediaPlaybackCache.dataSourceFactory"),
        )
        # 同一候选正在下载时不进缓存，只读远端。
        self.assertIn("if (!request.admitsPlaybackCache) return credentialed", section)
        for kind in ("SourceKind.REMOTE_HTTP ->", "SourceKind.REMOTE_HTTP_PROGRESSIVE ->"):
            branch = NATIVE_SESSION.split(kind, 1)[1].split("NativeMediaSessionRoute.SourceKind.", 1)[0]
            self.assertIn("remoteDataSources(request)", branch)
        # 本地会话不经过缓存：边下边播仍由 GrowingFileDataSource 提供。
        local = NATIVE_SESSION.split("SourceKind.LOCAL_GROWING_FILE ->", 1)[1].split(
            "SourceKind.REMOTE_HTTP ->", 1
        )[0]
        self.assertIn("GrowingFileDataSource.Factory()", local)
        self.assertNotIn("NativeMediaPlaybackCache", local)

    def test_cache_uses_media3_simple_cache_with_an_explicit_limit(self):
        self.assertIn("SimpleCache(root, NoOpCacheEvictor(), provider)", NATIVE_CACHE)
        self.assertIn("CacheDataSource.Factory()", NATIVE_CACHE)
        self.assertIn(".setUpstreamDataSourceFactory(upstream)", NATIVE_CACHE)
        self.assertIn("FLAG_IGNORE_CACHE_ON_ERROR", NATIVE_CACHE)
        self.assertIn("MAX_BYTES = 512L * 1024L * 1024L", CACHE_POLICY)
        self.assertIn("TARGET_BYTES = 384L * 1024L * 1024L", CACHE_POLICY)
        self.assertIn("fun evict(", CACHE_POLICY)
        # 回收发生在播放引擎释放之后，且只删媒体3 写下的条目。
        release = NATIVE_SESSION.split("private fun releaseMediaEngine()", 1)[1].split(
            "private fun detachSurfaceFromPlayer", 1
        )[0]
        self.assertIn("NativeMediaPlaybackCache.release(applicationContext)", release)
        self.assertLess(release.index("playerReleased = true"), release.index("NativeMediaPlaybackCache.release"))
        clear = NATIVE_CACHE.split("fun clear(context: Context)", 1)[1].split("fun sizeBytes", 1)[0]
        self.assertIn("cacheInstance?.release()", clear)
        self.assertIn("purgePlan(root)", clear)

    def test_cache_lives_in_its_own_directory_and_carries_the_station_identity(self):
        self.assertIn('DIRECTORY = "media_playback_cache"', CACHE_POLICY)
        self.assertIn("fun root(cacheDir: File): File = File(cacheDir, DIRECTORY)", CACHE_POLICY)
        self.assertIn('"profile=$profileId|host=$host"', CACHE_POLICY)
        self.assertIn("fun overlapsDownloadRoot(", CACHE_POLICY)
        bound = NATIVE_SESSION.split("private fun remoteDataSources(", 1)[1].split(
            "private fun headersFor", 1
        )[0]
        self.assertIn("overlapsDownloadRoot(cacheRoot, downloadRoot)", bound)
        # 下载目录与缓存目录是两个不同的根。
        self.assertIn("NativeMediaDownloadWorker.root(context)", DOWNLOAD_WORKER + DOWNLOAD_RUNTIME)
        self.assertIn("Environment.DIRECTORY_DOWNLOADS", DOWNLOAD_WORKER)
        self.assertNotIn("media_playback_cache", DOWNLOAD_WORKER)

    def test_playback_cache_is_clearable_without_touching_downloads(self):
        dispatch = DOWNLOAD_RUNTIME.split("override fun onMethodCall", 1)[1].split("private fun start", 1)[0]
        self.assertIn('"playbackCacheStatus" ->', dispatch)
        self.assertIn('"clearPlaybackCache" ->', dispatch)
        clear = DOWNLOAD_RUNTIME.split("private fun clearPlaybackCache()", 1)[1].split(
            "private fun start", 1
        )[0]
        self.assertIn("NativeMediaPlaybackCache.clear(context)", clear)
        self.assertNotIn("delete(", clear)
        self.assertNotIn("repository", clear)
        self.assertIn("clearPlaybackCache", NATIVE_LIBRARY)
        self.assertIn("Future<PlaybackCacheClearResult?> clearPlaybackCache()", APP_CONTROLLER)
        self.assertIn("clearPlaybackCache", DATA_MANAGEMENT)

    def test_download_ownership_decides_whether_one_fragment_is_cached(self):
        self.assertIn("fun admitPlayback(raw: String, downloadPaths: List<String>): Boolean", CACHE_POLICY)
        self.assertIn("fun ownedByDownload(raw: String, downloadPaths: List<String>): Boolean", CACHE_POLICY)
        admission = (ANDROID / "NativeMediaRuntime.kt").read_text()
        admit = admission.split("private fun playbackCacheAdmission", 1)[1].split(
            "private fun openLocal", 1
        )[0]
        self.assertIn("NativeMediaPlaybackCachePolicy.admitPlayback(", admit)
        self.assertIn("getOrDefault(true)", admit)
        self.assertIn("admitsPlaybackCache = admitted", admission)
        self.assertIn("val admitsPlaybackCache: Boolean = true", NATIVE_SESSION)
        self.assertIn("admitsPlaybackCache = admitsPlaybackCache", admission)
        # 缓存只决定取值范围，不改失败处置：远程重试仍由既有策略决定。
        self.assertIn("sourceRetryCount", NATIVE_SESSION)
        self.assertIn("CREDENTIAL_RESUME_DELAY_MS", NATIVE_SESSION)

    def test_cache_layer_is_documented_as_separate_from_downloads(self):
        self.assertIn("cacheDir/media_playback_cache", CACHE_ADR)
        self.assertIn("Download/site-lens", CACHE_ADR)
        self.assertIn("NoOpCacheEvictor", CACHE_ADR)


if __name__ == "__main__":
    unittest.main()
