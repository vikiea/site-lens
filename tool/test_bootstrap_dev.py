#!/usr/bin/env python3
"""Bootstrap safety, precedence, fresh-host planning, and failure regressions."""
from __future__ import annotations

import contextlib
import io
import json
import os
import subprocess
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path
from unittest.mock import patch

import bootstrap_dev as b


def completed(command=(), stdout="", stderr="", returncode=0):
    return subprocess.CompletedProcess(command, returncode, stdout, stderr)


class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="site-lens-bootstrap-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.stdout = contextlib.redirect_stdout(io.StringIO())
        self.stderr = contextlib.redirect_stderr(io.StringIO())
        self.stdout.__enter__()
        self.stderr.__enter__()
        self.addCleanup(self.stdout.__exit__, None, None, None)
        self.addCleanup(self.stderr.__exit__, None, None, None)

    def executable(self, relative):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("#!/bin/sh\nexit 0\n")
        path.chmod(0o755)
        return str(path)

    def sdk(self, name="sdk"):
        flutter = self.executable(f"{name}/bin/flutter")
        self.executable(f"{name}/bin/dart")
        return Path(flutter).parent

    def tools(self):
        return b.Tools(
            flutter="/sdk/bin/flutter", dart="/sdk/bin/dart", java="/jdk/bin/java",
            java_home=Path("/jdk"), android_home=self.root / "android",
            adb="/android/platform-tools/adb", emulator="/android/emulator/emulator",
            sdkmanager="/android/cmdline-tools/latest/bin/sdkmanager",
            avdmanager="/android/cmdline-tools/latest/bin/avdmanager",
            node="/node/bin/node", python="/python/bin/python3", openssl="/ssl/bin/openssl",
            codex="/usr/bin/codex", brew="/opt/homebrew/bin/brew",
        )

    def test_env_file_parser_supports_comments_quotes_and_export(self):
        env_file = self.root / ".env.local"
        env_file.write_text(
            "# comment\nexport FLUTTER_ROOT=\"/sdk/root\"\n"
            "ANDROID_HOME=/sdk/android # inline comment\n"
        )
        self.assertEqual(
            b.parse_env_file(env_file),
            {"FLUTTER_ROOT": "/sdk/root", "ANDROID_HOME": "/sdk/android"},
        )

    def test_unknown_env_variables_rejected_in_every_entrypoint(self):
        path = self.root / "bad.env"
        for content in ("DEVICE=personal-device", "PATH=/private/path", "TOKEN=secret"):
            path.write_text(content + "\n")
            with self.assertRaises(b.BootstrapError):
                b.parse_env_file(path)

    def test_real_test_sites_are_literal_https_values(self):
        path = self.root / 'sites.env'
        path.write_text('SITE_LENS_TEST_SITES=https://one.example/,https://two.example/entry/\n')
        self.assertEqual(b.parse_env_file(path)['SITE_LENS_TEST_SITES'],
                         'https://one.example/,https://two.example/entry/')
        for site in ('http://example.org', 'https://user:password@example.org',
                     'https://example.org/?token=secret', 'https://example.org/#fragment'):
            path.write_text('SITE_LENS_TEST_SITES=' + site + '\n')
            with self.assertRaises(b.BootstrapError):
                b.parse_env_file(path)

    def test_env_file_invalid_key_is_rejected(self):
        env_file = self.root / ".env.local"
        env_file.write_text("bad-key=/tmp/sdk\n")
        with self.assertRaises(b.BootstrapError):
            b.parse_env_file(env_file)

    def test_current_environment_overrides_env_file(self):
        file_sdk = self.sdk("file")
        process_sdk = self.sdk("process")
        env_file = self.root / ".env.local"
        env_file.write_text(f"FLUTTER_ROOT={file_sdk.parent}\n")
        env = {
            "SITE_LENS_ENV_FILE": str(env_file),
            "FLUTTER_ROOT": str(process_sdk.parent),
            "PATH": "",
        }
        tools = b.resolve_tools(env)
        self.assertEqual(Path(tools.flutter).parent.resolve(), process_sdk.resolve())

    def test_process_test_sites_are_validated_after_file_merge(self):
        with self.assertRaises(b.BootstrapError):
            b.project_environment({'SITE_LENS_TEST_SITES': 'https://example.org/?token=secret'})

    def test_direct_resolution_reads_project_env_file(self):
        file_sdk = self.sdk("file")
        env_file = self.root / ".env.local"
        env_file.write_text(f"FLUTTER_ROOT={file_sdk.parent}\n")
        with patch.object(b, "ROOT", self.root), patch.dict(
            os.environ, {"SITE_LENS_ENV_FILE": str(env_file), "PATH": ""}, clear=True
        ):
            tools = b.resolve_tools()
        self.assertEqual(Path(tools.flutter).parent.resolve(), file_sdk.resolve())

    def test_explicit_sdk_beats_path_and_uses_matching_dart(self):
        explicit, other = self.sdk("explicit"), self.sdk("other")
        tools = b.resolve_tools({"PATH": str(other), "FLUTTER_ROOT": str(explicit.parent)})
        self.assertEqual(tools.flutter, str(explicit / "flutter"))
        self.assertEqual(tools.dart, str(explicit / "dart"))

    def test_path_beats_fallback_sdk(self):
        on_path, fallback = self.sdk("on-path"), self.sdk("fallback")
        with patch.object(b, "DEFAULT_FLUTTER_BIN_DIR", fallback):
            tools = b.resolve_tools({"PATH": str(on_path)})
        self.assertEqual(Path(tools.flutter).parent.resolve(), on_path.resolve())

    def test_fallback_used_when_path_has_no_flutter(self):
        fallback = self.sdk("fallback")
        with patch.object(b, "DEFAULT_FLUTTER_BIN_DIR", fallback):
            tools = b.resolve_tools({"PATH": ""})
        self.assertEqual(tools.dart, str(fallback / "dart"))

    def test_invalid_explicit_sdk_does_not_silently_use_another(self):
        fallback = self.sdk("fallback")
        tools = b.resolve_tools({"PATH": str(fallback), "FLUTTER_ROOT": str(self.root / "missing")})
        self.assertIsNone(tools.flutter)
        self.assertIsNone(tools.dart)

    def test_explicit_java_and_android_paths(self):
        java = self.executable("jdk/bin/java")
        adb = self.executable("android/platform-tools/adb")
        tools = b.resolve_tools({"PATH": "", "JAVA_HOME": str(self.root / "jdk"), "ANDROID_HOME": str(self.root / "android")})
        self.assertEqual(tools.java, java)
        self.assertEqual(tools.adb, adb)

    def test_child_environment_propagates_sdk_paths(self):
        tools = self.tools()
        env = b.tool_env(tools)
        self.assertEqual(env["JAVA_HOME"], "/jdk")
        self.assertEqual(env["ANDROID_HOME"], str(tools.android_home))
        self.assertEqual(env["FLUTTER_ROOT"], "/sdk")
        self.assertEqual(env["PATH"].split(os.pathsep)[0], "/sdk/bin")

    def test_cli_root_overrides_inherited_bin_dir(self):
        with patch.dict(os.environ, {"FLUTTER_BIN_DIR": "/old/bin"}, clear=False), patch.object(b, "resolve_tools", return_value=b.Tools()) as resolve:
            try:
                b.main(["path", "flutter-bin", "--flutter-root", "/new"])
                self.assertEqual(os.environ["FLUTTER_ROOT"], "/new")
                self.assertNotIn("FLUTTER_BIN_DIR", os.environ)
                resolve.assert_called_once()
            finally:
                os.environ.pop("FLUTTER_ROOT", None)

    def test_make_command_line_sdk_alias_suppresses_file_alias(self):
        file_sdk = self.sdk("file")
        command_sdk = self.sdk("command")
        env_file = self.root / ".env.local"
        env_file.write_text(f"FLUTTER_BIN_DIR={file_sdk}\n")
        result = subprocess.run(
            ["make", "-n", f"ENV_FILE={env_file}", f"FLUTTER_ROOT={command_sdk.parent}", "analyze"],
            cwd=b.ROOT,
            capture_output=True,
            text=True,
            env={**os.environ, "PATH": os.environ.get("PATH", "")},
            timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(str(command_sdk / "flutter"), result.stdout)
        self.assertNotIn(str(file_sdk / "flutter"), result.stdout)

    def make_probe(self, content, assignments=(), shell_values=None):
        path = self.root / "probe.env"
        path.write_text(content)
        probe = self.root / "probe.mk"
        probe.write_text("probe:\n\t@python3 -c 'import os,json; print(json.dumps({k:os.environ.get(k) for k in [\"FLUTTER_ROOT\",\"FLUTTER_BIN_DIR\",\"ANDROID_HOME\",\"ANDROID_SDK_ROOT\",\"AVD_NAME\",\"AVD_IMAGE\",\"SITE_LENS_SIGNING_PROPERTIES\"]}))'\n")
        environment = {**os.environ}
        for key in b.MAKE_ENV_KEYS:
            environment.pop(key, None)
            environment.pop("SITE_LENS_ENV_ORIGIN_" + key, None)
        for key in ("MAKEFLAGS", "MFLAGS", "MAKEOVERRIDES"):
            environment.pop(key, None)
        environment.update(shell_values or {})
        result = subprocess.run(["make", "--no-print-directory", "-s", "-f", "Makefile", "-f", str(probe), f"ENV_FILE={path}", *assignments, "probe"], cwd=b.ROOT, env=environment, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_make_multivariable_file_propagates_all_settings(self):
        result = self.make_probe("FLUTTER_ROOT=/file/flutter\nJAVA_HOME=/file/java\nANDROID_HOME=/file/android\nAVD_NAME=local-avd\nAVD_IMAGE=system-images;android-36;google_apis;arm64-v8a\nSITE_LENS_SIGNING_PROPERTIES=/outside/signing.properties\n")
        self.assertEqual(result["FLUTTER_ROOT"], "/file/flutter")
        self.assertEqual(result["FLUTTER_BIN_DIR"], "/file/flutter/bin")
        self.assertEqual(result["AVD_NAME"], "local-avd")
        self.assertEqual(result["SITE_LENS_SIGNING_PROPERTIES"], "/outside/signing.properties")
        self.assertEqual(result["AVD_IMAGE"], "system-images;android-36;google_apis;arm64-v8a")

    def test_android_command_line_alias_beats_shell_and_file(self):
        result = self.make_probe("ANDROID_HOME=/file/sdk\n", ["ANDROID_SDK_ROOT=/command/sdk"], {"ANDROID_HOME": "/shell/sdk"})
        self.assertEqual(result["ANDROID_HOME"], "/command/sdk")
        self.assertEqual(result["ANDROID_SDK_ROOT"], "/command/sdk")

    def test_flutter_command_line_root_beats_shell_bin(self):
        result = self.make_probe("FLUTTER_BIN_DIR=/file/bin\n", ["FLUTTER_ROOT=/command/sdk"], {"FLUTTER_BIN_DIR": "/shell/bin"})
        self.assertEqual(result["FLUTTER_BIN_DIR"], "/command/sdk/bin")

    def test_same_layer_alias_preference_matches_python(self):
        result = self.make_probe("FLUTTER_ROOT=/file/root\nFLUTTER_BIN_DIR=/file/bin\nANDROID_HOME=/file/home\nANDROID_SDK_ROOT=/file/other\n")
        self.assertEqual(result["FLUTTER_BIN_DIR"], "/file/bin")
        self.assertEqual(result["ANDROID_HOME"], "/file/home")

    def test_jdk_and_fixed_version_parsing(self):
        self.assertEqual(b._major('openjdk version "21.0.11" 2026-04-21'), "21")
        self.assertEqual(b.parse_flutter_version("Flutter 3.47.6 • stable"), b.EXPECTED_FLUTTER)
        self.assertEqual(b.parse_dart_version("Dart SDK version: 3.13.5 (stable)"), b.EXPECTED_DART)

    def test_missing_tools_and_sdk_are_required_failures(self):
        with patch.object(b, "_output", return_value="Python 3.14.6"):
            checks = b.baseline_diagnostics(b.Tools(python="python3"))
        failures = {c.name for c in checks if c.status == "FAIL"}
        self.assertTrue({"Flutter", "Dart", "JDK", "Node.js", "Android Platform 36"} <= failures)
        self.assertEqual(b.print_diagnostics(checks), 1)

    def test_version_mismatch_blocks_before_any_project_write(self):
        with patch.object(b, "resolve_tools", return_value=self.tools()), patch.object(b, "baseline_diagnostics", return_value=[b.Diagnostic("FAIL", "Flutter", "3.48; expected 3.47.6")]), patch.object(b, "_run") as run:
            self.assertEqual(b.main(["project"]), 2)
        run.assert_not_called()

    def test_project_only_pub_and_pigeon_and_honors_lock(self):
        with patch.object(b, "resolve_tools", return_value=self.tools()), patch.object(b, "baseline_diagnostics", return_value=[]), patch.object(b, "_output", return_value=""), patch.object(b, "_run") as run:
            b.project_setup()
        commands = [call.args[0] for call in run.call_args_list]
        self.assertEqual(commands, [
            ["/sdk/bin/flutter", "pub", "get", "--enforce-lockfile"],
            ["/sdk/bin/dart", "run", "pigeon", "--input", "pigeons/web_host.dart"],
        ])

    def test_local_generated_edits_are_never_overwritten(self):
        with patch.object(b, "resolve_tools", return_value=self.tools()), patch.object(b, "baseline_diagnostics", return_value=[]), patch.object(b, "_output", return_value=" M lib/web_host/web_host.g.dart"), patch.object(b, "_run") as run:
            self.assertEqual(b.main(["project"]), 2)
        run.assert_not_called()

    def test_failed_dependency_resolution_does_not_run_codegen(self):
        with patch.object(b, "resolve_tools", return_value=self.tools()), patch.object(b, "baseline_diagnostics", return_value=[]), patch.object(b, "_output", return_value=""), patch.object(b, "_run", side_effect=b.BootstrapError("pub failure")) as run:
            self.assertEqual(b.main(["project"]), 2)
        self.assertEqual(run.call_count, 1)

    def pigeon_fixture(self):
        (self.root / ".dart_tool").mkdir()
        config = self.root / ".dart_tool/package_config.json"
        config.write_text(json.dumps({"packages": [{"name": "pigeon", "rootUri": "file:///cache/pigeon-29.0.7"}]}))
        (self.root / "pubspec.lock").write_text("LOCKED\n")
        for relative in b.PIGEON_GENERATED:
            (self.root / relative).parent.mkdir(parents=True, exist_ok=True)
            (self.root / relative).write_text("current\n")
        return config

    def test_pigeon_checks_current_tree_without_dart_run_or_symlinks(self):
        config = self.pigeon_fixture()
        before = {p: p.read_bytes() for p in self.root.rglob("*") if p.is_file()}

        def generate(command, **kwargs):
            self.assertNotIn("run", command)
            self.assertIn(f"--packages={config}", command)
            self.assertFalse(any(p.is_symlink() for p in kwargs["cwd"].rglob("*")))
            for relative in b.PIGEON_GENERATED:
                out = kwargs["cwd"] / relative
                out.parent.mkdir(parents=True, exist_ok=True)
                out.write_text("current\n")
            return completed(command)

        with patch.object(b, "ROOT", self.root), patch.object(b, "_run", side_effect=generate):
            self.assertEqual(b._pigeon_diagnostics(self.tools())[0].status, "PASS")
        self.assertEqual(before, {p: p.read_bytes() for p in self.root.rglob("*") if p.is_file()})

    def test_pigeon_stale_binding_is_a_failure(self):
        self.pigeon_fixture()
        with patch.object(b, "ROOT", self.root), patch.object(b, "_run", return_value=completed()):
            self.assertEqual(b._pigeon_diagnostics(self.tools())[0].status, "FAIL")

    def system_context(self):
        return contextlib.ExitStack()

    def run_system(self, *, dry_run=False, avds="", fail_list=False, fresh=False):
        tools = self.tools()
        if fresh:
            tools = b.Tools(brew="/brew")
        commands = []

        def output(command, **kwargs):
            if command[-1] == "--prefix":
                return str(self.root / "brew")
            if "avdmanager" in command[0] and command[1:] == ["list", "avd"]:
                if fail_list:
                    raise b.BootstrapError("AVD listing failed")
                return avds
            return ""

        def run(command, **kwargs):
            commands.append((command, kwargs))
            return completed(command)

        with patch.object(b.platform, "system", return_value="Darwin"), patch.object(b.platform, "machine", return_value="arm64"), patch.object(b, "DEFAULT_FLUTTER_BIN_DIR", self.root / "new-flutter/bin"), patch.object(b, "resolve_tools", return_value=tools), patch.object(b, "_brew_installed", return_value=not fresh), patch.object(b, "_output", side_effect=output), patch.object(b, "_run", side_effect=run):
            b.system_setup(dry_run=dry_run)
        return commands

    def test_fresh_host_system_dry_run_prints_all_install_commands(self):
        with patch.dict(os.environ, {"AVD_NAME": "new-avd"}):
            calls = self.run_system(dry_run=True, fresh=True)
        commands = [command for command, _ in calls]
        self.assertTrue(any("--cask" in c and "android-commandlinetools" in c for c in commands))
        self.assertTrue(any("platforms;android-36" in c for c in commands))
        self.assertTrue(any(b.FLUTTER_REVISION in c for c in commands))
        self.assertTrue(all(kwargs["dry_run"] for _, kwargs in calls))
        self.assertFalse((self.root / "new-flutter").exists())

    def test_avd_image_installed_before_creation_without_force(self):
        with patch.dict(os.environ, {"AVD_NAME": "new-avd"}):
            calls = self.run_system()
        commands = [c for c, _ in calls]
        create = next(i for i, c in enumerate(commands) if c[1:3] == ["create", "avd"])
        self.assertIn("system-images;android-36;google_apis;arm64-v8a", commands[create - 1])
        self.assertNotIn("--force", commands[create])
        self.assertEqual(calls[create][1]["input_text"], "no\n")

    def test_existing_avd_is_preserved(self):
        with patch.dict(os.environ, {"AVD_NAME": "existing"}):
            calls = self.run_system(avds="    Name: existing\n    Path: /user/device\n")
        self.assertFalse(any("create" in c for c, _ in calls))

    def test_failed_avd_listing_cannot_trigger_creation(self):
        with patch.dict(os.environ, {"AVD_NAME": "new-avd"}):
            with self.assertRaisesRegex(b.BootstrapError, "listing failed"):
                self.run_system(fail_list=True)

    def test_system_failure_stops_before_sdk_install(self):
        with patch.object(b.platform, "system", return_value="Darwin"), patch.object(b, "resolve_tools", return_value=self.tools()), patch.object(b, "_brew_installed", return_value=False), patch.object(b, "_run", side_effect=b.BootstrapError("brew failed")) as run:
            self.assertEqual(b.main(["system"]), 2)
        self.assertEqual(run.call_count, 1)

    def test_non_macos_system_install_is_explicit_failure(self):
        with patch.object(b.platform, "system", return_value="Linux"), patch.object(b, "_run") as run:
            self.assertEqual(b.main(["system"]), 2)
        run.assert_not_called()

    def test_plugin_status_requires_installed_and_enabled(self):
        data = {"installed": [{"pluginId": b.PLUGIN_ID, "installed": True, "enabled": False}]}
        with patch.object(b, "_output", return_value=json.dumps(data)):
            record = b.plugin_record(self.tools())
        self.assertFalse(record["enabled"])

    def test_already_enabled_agent_is_idempotent(self):
        record = {"installed": True, "enabled": True, "version": "1.0.6"}
        marketplaces = {"marketplaces": [{"name": "dart-flutter", "marketplaceSource": {"source": "https://github.com/flutter/agent-plugins.git"}}]}
        with patch.object(b, "resolve_tools", return_value=self.tools()), patch.object(b, "_agent_path"), patch.object(b, "plugin_record", return_value=record), patch.object(b, "_output", return_value=json.dumps(marketplaces)), patch.object(b, "_run") as run:
            b.agent_setup()
        self.assertEqual([c.args[0] for c in run.call_args_list], [["/sdk/bin/dart", "mcp-server", "--version"]])

    def test_disabled_plugin_after_install_is_not_success(self):
        with patch.object(b, "resolve_tools", return_value=self.tools()), patch.object(b, "_agent_path"), patch.object(b, "plugin_record", return_value={"installed": True, "enabled": False}), patch.object(b, "_output", return_value='{"marketplaces": []}'), patch.object(b, "_run"):
            self.assertEqual(b.main(["agent"]), 2)

    def test_plugin_install_error_is_not_swallowed(self):
        with patch.object(b, "resolve_tools", return_value=self.tools()), patch.object(b, "_agent_path"), patch.object(b, "_output", return_value='{"marketplaces": []}'), patch.object(b, "_run", side_effect=b.BootstrapError("plugin not installed")):
            self.assertEqual(b.main(["agent"]), 2)

    def test_missing_commands_get_links_without_overwriting(self):
        local_bin = self.root / ".local/bin"
        sdk = self.sdk()
        tools = replace(self.tools(), flutter=str(sdk / "flutter"), dart=str(sdk / "dart"))
        with patch.object(Path, "home", return_value=self.root), patch.dict(os.environ, {"SITE_LENS_PARENT_PATH": str(local_bin)}):
            b._agent_path(tools, dry_run=True)
            self.assertFalse(local_bin.exists())
            b._agent_path(tools, dry_run=False)
            b._agent_path(tools, dry_run=False)
        self.assertEqual((local_bin / "dart").resolve(), sdk.joinpath("dart").resolve())

    def test_timeout_has_stable_failure_not_traceback(self):
        with patch.object(b.subprocess, "run", side_effect=subprocess.TimeoutExpired("flutter", 10)):
            with self.assertRaises(b.BootstrapError):
                b._run(["flutter", "--version"])


if __name__ == "__main__":
    unittest.main()
