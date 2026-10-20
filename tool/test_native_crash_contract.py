#!/usr/bin/env python3
"""Read-only contracts for WebView renderer recovery and exit diagnostics."""

from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "android/app/src/main/kotlin/dev/vikiea/site_lens"


def block(source, signature):
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 1
    offset = opening + 1
    # Kotlin braces in comments/strings are ignored, including interpolation.
    token = re.compile(r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"|[{}]', re.S)
    for match in token.finditer(source, offset):
        if match.group() == "{":
            depth += 1
        elif match.group() == "}":
            depth -= 1
            if depth == 0:
                return source[opening + 1:match.start()]
    raise AssertionError("unbalanced Kotlin block: " + signature)


class NativeCrashContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.host = (SOURCE / "NativeWebHost.kt").read_text()
        cls.store = (SOURCE / "NativeCrashStore.kt").read_text()
        cls.activity = (SOURCE / "MainActivity.kt").read_text()

    def test_every_webview_client_handles_renderer_death(self):
        clients = list(re.finditer(r"object\s*:\s*WebViewClient\(\)\s*\{", self.host))
        self.assertGreaterEqual(len(clients), 2)
        for client in clients:
            body = block(self.host[client.start():], "object : WebViewClient()")
            renderer = block(body, "override fun onRenderProcessGone")
            self.assertIn("return true", renderer)
            for forbidden in ("webView.url", "view.url", "probe.url", ".post {", "revoke()", "media."):
                self.assertNotIn(forbidden, renderer)

    def test_dead_cleanup_does_not_call_provider_or_media(self):
        body = block(self.host, "private fun disposeAfterRendererGone")
        for forbidden in ("WebViewCompat.", ".stopLoading(", "media.dispose(", ".evaluateJavascript(", ".onPause(", ".onResume("):
            self.assertNotIn(forbidden, body)
        self.assertIn("deadView.destroy()", body)
        self.assertIn("removeView", body)
        self.assertIn("media.rendererGone()", body)
        self.assertIn("clearPopupProbes()", body)
        self.assertIn("clearProbeProfile()", body)

    def test_popup_disposal_does_not_depend_on_attachment(self):
        body = block(self.host, "override fun onCreateWindow")
        self.assertNotIn("probe.post", body)
        self.assertIn("mainHandler.post", body)
        self.assertIn("postDelayed", body)
        self.assertIn("probeDestroyed", body)

    def test_event_url_does_not_use_a_webview_getter(self):
        body = block(self.host, "private fun event")
        self.assertNotIn("webView.url", body)
        self.assertIn("lastKnownUrl", body)

    def test_history_traversal_is_not_rewritten_as_load_url(self):
        body = block(self.host, "override fun shouldOverrideUrlLoading")
        self.assertIn("historyLoading", body)
        self.assertIn("sameHistoryTarget", body)
        self.assertIn("return false", body)
        self.assertIn("prepareNavigation", body)
        self.assertIn("revoke()", body)

    def test_history_marker_is_cleared_only_after_commit_or_revoke(self):
        completed = block(self.host, "override fun onNavigationCompleted")
        self.assertIn("clearHistoryNavigation()", completed)
        revoked = block(self.host, "fun revoke()")
        self.assertIn("clearHistoryNavigation()", revoked)

    def test_page_navigation_waits_for_old_injections_to_be_removed(self):
        body = block(self.host, "fun prepareNavigation(")
        page = block(body, "if (!installScripts)")
        self.assertIn("mainHandler.post", page)
        self.assertIn("!available || generation != ticket", page)
        self.assertLess(page.index("mainHandler.post"), page.index("load()"))

    def test_entry_redirect_lease_keeps_navigation_identity(self):
        body = block(self.host, "override fun onNavigationStarted")
        self.assertIn("entryNavigation === navigation", body)
        self.assertIn("entryHops < MAX_ENTRY_REDIRECTS", body)
        self.assertIn("!entryRedirectLease", body)

    def test_fullscreen_has_one_registry_owner_and_rejects_stale_disable(self):
        registry = block(self.host, "class NativeWebHostRegistry")
        self.assertIn("fullscreenOwner", registry)
        self.assertIn("requestFullscreen", registry)
        self.assertIn("if (!enabled && fullscreenOwner !== host) return", registry)
        self.assertIn("releaseFullscreen", registry)
        self.assertIn("onHostFullscreenChanged", registry)
        self.assertNotIn("setDecorFitsSystemWindows(window, true)", registry)
        self.assertIn("onFullscreenChanged", self.host)
        self.assertIn("forceClearFullscreen", self.host)

    def test_exit_history_is_version_guarded_and_deduplicated(self):
        body = block(self.store, "fun drainIncludingHistoricalExits")
        self.assertIn("Build.VERSION_CODES.R", body)
        capture = block(self.store, "private fun captureHistoricalExits")
        self.assertIn("getHistoricalProcessExitReasons(context.packageName", capture)
        for reason in ("CRASH_NATIVE", "ANR", "LOW_MEMORY", "SIGNALED"):
            self.assertIn("ApplicationExitInfo.REASON_" + reason, capture)
        self.assertIn("if (key in seen) continue", capture)
        self.assertIn("if (recorded) seen.add(key)", capture)

    def test_tombstone_is_bounded_binary_and_never_decoded_as_text(self):
        body = block(self.store, "private fun captureExitTrace")
        self.assertIn("Build.VERSION_CODES.S", body)
        self.assertIn('".pb"', body)
        self.assertIn("MAX_TRACE_BYTES", body)
        self.assertIn("output.write(bytes)", body)
        for forbidden in ("bufferedReader", "readText", "String(bytes", "readNBytes"):
            self.assertNotIn(forbidden, body)

    def test_fatal_file_is_synced_before_stream_close(self):
        body = block(self.store, "private fun appendRow")
        self.assertIn("output.fd.sync()", body)
        self.assertNotIn("OutputStreamWriter", body)

    def test_read_is_non_destructive_until_dart_acknowledges(self):
        body = block(self.store, "fun drain(context")
        self.assertNotIn("file.delete()", body)
        ack = block(self.store, "fun acknowledge")
        self.assertIn("remaining", ack)
        self.assertIn("output.fd.sync()", ack)
        self.assertIn("temporary.renameTo(file)", ack)

    def test_diagnostics_runs_off_ui_thread_and_replies_on_main(self):
        body = block(self.activity, "private fun registerDiagnosticsChannel")
        self.assertIn("Executors.newSingleThreadExecutor", body)
        self.assertIn("drainIncludingHistoricalExits", body)
        self.assertIn("mainHandler.post", body)
        self.assertIn("if (generation != diagnosticsGeneration) return@post", body)
        cleanup = block(self.activity, "override fun cleanUpFlutterEngine")
        self.assertIn("diagnosticsGeneration++", cleanup)
        self.assertIn("diagnosticsExecutor?.shutdown", cleanup)


if __name__ == "__main__":
    unittest.main()
