#!/usr/bin/env python3
"""Read-only source contracts for WebView media ownership and frame control."""

from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
ANDROID = ROOT / "android/app/src/main/kotlin/dev/vikiea/site_lens"
CONTROLLER = (ANDROID / "BrowserMediaController.kt").read_text()
HOST = (ANDROID / "NativeWebHost.kt").read_text()
SERVICE = (ANDROID / "BrowserMediaService.kt").read_text()
LIFECYCLE = (ROOT / "web_assets/media_lifecycle.js").read_text()
TRANSFER = (ANDROID / "ResumableMediaTransfer.kt").read_text()
DOWNLOAD_RUNTIME = (ANDROID / "NativeDownloadRuntime.kt").read_text()
NATIVE_MEDIA = (ANDROID / "NativeMediaRuntime.kt").read_text()
NATIVE_SESSION = (ANDROID / "NativeMediaSessionService.kt").read_text()
AUTH_REFRESH = (ANDROID / "NativeMediaAuthRefreshService.kt").read_text()
NATIVE_EXPORT = (ANDROID / "NativeExportRuntime.kt").read_text()
NATIVE_LEASES = (ANDROID / "NativeMediaFileLeases.kt").read_text()

# REGRESSION CONTRACT: MEDIA-HLS-001


class NativeMediaContractTests(unittest.TestCase):
    def test_native_playback_file_lease_contract_is_fail_closed(self):
        self.assertIn('class MediaFileLeaseRegistry', NATIVE_LEASES)
        for token in ('acquireRead', 'acquireMutation', 'overlaps', 'taskIds', 'documents'):
            self.assertIn(token, NATIVE_LEASES)
        local = NATIVE_MEDIA.split('private fun openLocal(', 1)[1].split('private fun start(', 1)[0]
        self.assertIn('openInService(', local)
        self.assertLess(local.index('openFileDescriptor'), local.index('openInService'))
        self.assertIn('Uri.fromFile(file).toString()', local)
        self.assertIn('MediaFileLeaseRegistry.Scope.file(File(uri.path!!).parentFile!!)', NATIVE_SESSION)
        self.assertIn('NativeMediaFileLeases.registry.acquireRead(leaseScope)', NATIVE_SESSION)
        self.assertLess(NATIVE_SESSION.index('acquireRead(leaseScope)'), NATIVE_SESSION.index('player.setMediaItem'))
        stop = NATIVE_MEDIA.split('private fun stopLocalPlayer()', 1)[1].split('private fun ensureTexture(', 1)[0]
        self.assertLess(stop.index('media.release()'), stop.index('fileLease?.close()'))

    def test_native_media_session_service_owns_background_player_and_promotes_foreground(self):
        self.assertIn('class NativeMediaSessionService : MediaSessionService()', NATIVE_SESSION)
        for token in (
            'MediaSession.Builder(this, player)',
            'override fun onGetSession',
            'startForeground(ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)',
            'setHandleAudioBecomingNoisy(true)',
            'private var userPaused = false',
            'userPaused -> "paused"',
            'fileLease?.close()',
            '"backend" to "media_session"',
        ):
            self.assertIn(token, NATIVE_SESSION)
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

    def test_local_service_replacement_does_not_stop_the_service(self):
        self.assertIn('stopLocalPlayer()', NATIVE_MEDIA)
        replacement = NATIVE_MEDIA.split('private fun openInService(', 1)[1].split(
            'private fun start(', 1
        )[0]
        self.assertNotIn('NativeMediaSessionService.stop(context)', replacement)

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
            'origin(next) != pageOrigin',
            'onCreateWindow',
            'setSupportMultipleWindows(false)',
            '"waiting_execution"',
            '"reauthorize"',
            'CookieManager.getInstance().getCookie',
            '"cookieDigest" to digest',
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

    def test_native_mutations_take_file_leases_before_cancellation_or_delete(self):
        download = (ANDROID / "NativeDownloadRuntime.kt").read_text()
        export = NATIVE_EXPORT
        self.assertIn('NativeMediaFileLeases.registry.mutate(scope)', download)
        self.assertIn('reserveMutation', download)
        self.assertIn('mutationReservations', download)
        for token in (
            'directoryMigrationJournal',
            'rewriteSeriesDirectory',
            'withDirectoryLocks',
            'LinkOption.NOFOLLOW_LINKS',
            'newName in activeDirectories',
            'ownsMutationReservation',
            'fun dispose()',
        ):
            self.assertIn(token, download)
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

    def test_controller_publishes_foreground_owner_before_background(self):
        self.assertIn("if (!allowed) { stopService(); return }", CONTROLLER)
        self.assertIn("BrowserMediaService.update(", CONTROLLER)
        self.assertNotIn("if (!allowed || !background)", CONTROLLER)
        self.assertIn("if (run || (allowed && background)) view.onResume()", CONTROLLER)

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
        self.assertIn('媒体分段响应缺少验证标识', TRANSFER)
        self.assertIn('publishIfActive', TRANSFER)

    def test_native_playback_claims_media_audio_focus(self):
        self.assertIn("setAudioAttributes", NATIVE_MEDIA)
        self.assertIn("C.USAGE_MEDIA", NATIVE_MEDIA)
        self.assertIn("setHandleAudioBecomingNoisy(true)", NATIVE_MEDIA)

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


if __name__ == "__main__":
    unittest.main()
