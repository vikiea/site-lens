#!/usr/bin/env python3
"""Read-only source contracts for WebView media ownership and frame control."""

from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
ANDROID = ROOT / "android/app/src/main/kotlin/dev/vikiea/site_lens"
CONTROLLER = (ANDROID / "BrowserMediaController.kt").read_text()
SERVICE = (ANDROID / "BrowserMediaService.kt").read_text()
LIFECYCLE = (ROOT / "web_assets/media_lifecycle.js").read_text()
TRANSFER = (ANDROID / "ResumableMediaTransfer.kt").read_text()
DOWNLOAD_RUNTIME = (ANDROID / "NativeDownloadRuntime.kt").read_text()
NATIVE_MEDIA = (ANDROID / "NativeMediaRuntime.kt").read_text()
NATIVE_EXPORT = (ANDROID / "NativeExportRuntime.kt").read_text()


class NativeMediaContractTests(unittest.TestCase):
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
        self.assertTrue("nativeValidatePath(file.path, base.canonicalPath)" in resources,
                        "HLS resources must stay inside the playlist directory tree")
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


if __name__ == "__main__":
    unittest.main()
