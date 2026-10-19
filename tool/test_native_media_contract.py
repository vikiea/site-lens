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

    def test_native_transfer_keeps_range_validator_and_partial_bytes(self):
        self.assertIn('setRequestProperty("Range", "bytes=$offset-")', TRANSFER)
        self.assertIn('setRequestProperty("If-Range", validator)', TRANSFER)
        self.assertIn('Content-Range', TRANSFER)
        self.assertIn('RandomAccessFile(partial, "rw")', TRANSFER)
        self.assertIn('partial.length()', TRANSFER)
        self.assertIn('媒体分段响应缺少验证标识', TRANSFER)
        self.assertIn('publishIfActive', TRANSFER)

    def test_legacy_migration_can_recover_a_staged_copy(self):
        self.assertIn('stagedFinal = File(finalTarget.path + ".legacy.tmp")', DOWNLOAD_RUNTIME)
        self.assertIn('stagedPartial = File(partialTarget.path + ".legacy.tmp")', DOWNLOAD_RUNTIME)
        self.assertIn('commitLegacyCopy(stagedFinal, finalTarget)', DOWNLOAD_RUNTIME)
        self.assertIn('commitLegacyCopy(stagedPartial, partialTarget)', DOWNLOAD_RUNTIME)
        self.assertIn('private fun commitLegacyCopy', DOWNLOAD_RUNTIME)
        self.assertIn('if (staged.exists()) runCatching { staged.delete() }', DOWNLOAD_RUNTIME)


if __name__ == "__main__":
    unittest.main()
