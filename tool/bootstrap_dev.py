#!/usr/bin/env python3
"""Project setup, explicit macOS SDK/agent installation, and read-only diagnosis."""
from __future__ import annotations

import argparse
import json
import os
import platform
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Mapping, Sequence
from urllib.parse import unquote, urljoin, urlparse

ROOT = Path(__file__).resolve().parents[1]
EXPECTED_FLUTTER = "3.47.6"
EXPECTED_DART = "3.13.5"
FLUTTER_REVISION = "5fc346839b5d0eef006ed8404392afb4dfae428d"
EXPECTED_NDK = "28.2.13676358"
DEFAULT_FLUTTER_BIN_DIR = Path.home() / ".local/share/flutter/bin"
DEFAULT_ANDROID_HOMES = (
    Path.home() / "Library/Android/sdk",
    Path("/opt/homebrew/share/android-commandlinetools"),
    Path("/usr/local/share/android-commandlinetools"),
)
DEFAULT_JAVA_HOMES = tuple(
    Path(prefix) / "opt/openjdk@21/libexec/openjdk.jdk/Contents/Home"
    for prefix in ("/opt/homebrew", "/usr/local")
)
PIGEON_GENERATED = (
    "lib/web_host/web_host.g.dart",
    "android/app/src/main/kotlin/dev/vikiea/site_lens/WebHost.g.kt",
    "ios/Runner/WebHost.g.swift",
)
SYSTEM_SDK_PACKAGES = (
    "platform-tools", "platforms;android-36", "build-tools;36.0.0",
    "emulator", f"ndk;{EXPECTED_NDK}",
)
PLUGIN_ID = "dart-flutter@dart-flutter"
ENV_FILE_NAME = ".env.local"
MAKE_ENV_KEYS = (
    "FLUTTER_ROOT", "FLUTTER_BIN_DIR", "ANDROID_HOME", "ANDROID_SDK_ROOT",
    "JAVA_HOME", "EMULATOR_AVD", "AVD_NAME", "AVD_IMAGE", "SITE_LENS_SIGNING_PROPERTIES",
)


class BootstrapError(RuntimeError):
    """An actionable setup failure (exit 2)."""


@dataclass(frozen=True)
class Tools:
    flutter: str | None = None
    dart: str | None = None
    java: str | None = None
    adb: str | None = None
    emulator: str | None = None
    sdkmanager: str | None = None
    avdmanager: str | None = None
    node: str | None = None
    python: str | None = None
    openssl: str | None = None
    codex: str | None = None
    brew: str | None = None
    android_home: Path | None = None
    java_home: Path | None = None


@dataclass(frozen=True)
class Diagnostic:
    status: str
    name: str
    detail: str


def _executable(path: Path) -> str | None:
    return str(path) if path.is_file() and os.access(path, os.X_OK) else None


def env_file_path(env: Mapping[str, str] | None = None) -> Path:
    source = env if env is not None else os.environ
    configured = source.get("SITE_LENS_ENV_FILE", "").strip()
    path = Path(configured).expanduser() if configured else ROOT / ENV_FILE_NAME
    return path if path.is_absolute() else ROOT / path


def parse_env_file(path: Path) -> dict[str, str]:
    """Parse plain allowlisted KEY=value data; never evaluate shell/Make syntax."""
    if not path.exists():
        return {}
    if not path.is_file():
        raise BootstrapError(f"environment file is not a regular file: {path}")
    values: dict[str, str] = {}
    for line_number, raw in enumerate(path.read_text().splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].lstrip()
        key, separator, value = line.partition("=")
        key = key.strip()
        location = f"{path}:{line_number}"
        if not separator or key not in MAKE_ENV_KEYS:
            raise BootstrapError(f"unsupported variable or invalid assignment at {location}; use .env.example")
        if key in values:
            raise BootstrapError(f"duplicate variable {key} at {location}")
        value = value.strip()
        if value.startswith(("'", '\"')):
            quote = value[0]
            close = value.find(quote, 1)
            if close < 0 or (value[close + 1:].strip() and not value[close + 1:].strip().startswith("#")):
                raise BootstrapError(f"invalid quoted value at {location}")
            value = value[1:close]
        else:
            value = value.split(" #", 1)[0].rstrip()
        if "$" in value or "`" in value or "\\" in value:
            raise BootstrapError(f"shell expansion and escape syntax are unsupported at {location}; use literal paths")
        if value and key not in {"EMULATOR_AVD", "AVD_NAME", "AVD_IMAGE"}:
            value = str(Path(value).expanduser())
            if not Path(value).is_absolute():
                raise BootstrapError(f"{key} must be an absolute path or start with ~ at {location}")
        values[key] = value
    return values


SDK_ALIASES = (("FLUTTER_ROOT", "FLUTTER_BIN_DIR"), ("ANDROID_HOME", "ANDROID_SDK_ROOT"))


def file_defaults(env: Mapping[str, str]) -> dict[str, str]:
    values = parse_env_file(env_file_path(env))
    # A higher-priority SDK selection beats every alias from the local file.
    for aliases in SDK_ALIASES:
        if any(env.get(key) for key in aliases):
            for key in aliases:
                values.pop(key, None)
    return values


def project_environment(env: Mapping[str, str] | None = None) -> dict[str, str]:
    if env is None:
        return {**file_defaults(os.environ), **os.environ}
    # Explicit mappings are complete snapshots, useful for callers/tests; only
    # load a project file when the snapshot names one explicitly.
    if "SITE_LENS_ENV_FILE" in env:
        return {**file_defaults(env), **env}
    return dict(env)


def env_value(path: Path, key: str) -> str:
    if key not in MAKE_ENV_KEYS:
        raise BootstrapError(f"unsupported Make environment variable: {key}")
    return file_defaults({**os.environ, "SITE_LENS_ENV_FILE": str(path)}).get(key, "")


def configuration_diagnostics() -> list[Diagnostic]:
    path = env_file_path()
    values = parse_env_file(path)
    checks = [Diagnostic("PASS", "Project environment", str(path) if path.exists() else f"{path} absent; automatic discovery")]
    for key in MAKE_ENV_KEYS:
        marker = os.environ.get(f"SITE_LENS_ENV_ORIGIN_{key}")
        if marker:
            origin = marker
        elif key in os.environ:
            origin = "process environment"
        elif key in values:
            origin = str(path)
        else:
            continue
        checks.append(Diagnostic("PASS", f"Config source {key}", origin))
    return checks


def resolve_tools(env: Mapping[str, str] | None = None) -> Tools:
    """Explicit SDK directory, then PATH, then known macOS locations.

    An invalid explicit SDK is reported rather than silently selecting another.
    Dart is selected from Flutter's SDK to avoid mixing two installations.
    """
    env = project_environment(env)

    def which(name: str) -> str | None:
        return shutil.which(name, path=env.get("PATH", ""))

    explicit_flutter = env.get("FLUTTER_BIN_DIR")
    if not explicit_flutter and env.get("FLUTTER_ROOT"):
        explicit_flutter = str(Path(env["FLUTTER_ROOT"]).expanduser() / "bin")
    if explicit_flutter:
        flutter_bin = Path(explicit_flutter).expanduser()
    else:
        flutter = which("flutter")
        flutter_bin = Path(flutter).resolve().parent if flutter else DEFAULT_FLUTTER_BIN_DIR
    flutter = _executable(flutter_bin / "flutter")
    dart = _executable(flutter_bin / "dart")
    if not flutter and not explicit_flutter:
        dart = which("dart") or dart

    explicit_android = env.get("ANDROID_HOME") or env.get("ANDROID_SDK_ROOT")
    if explicit_android:
        android = Path(explicit_android).expanduser()
    elif which("adb"):
        android = Path(which("adb")).resolve().parent.parent
    elif which("sdkmanager"):
        android = Path(which("sdkmanager")).resolve().parents[3]
    else:
        android = next((p for p in DEFAULT_ANDROID_HOMES if p.is_dir()), None)

    java_home = Path(env["JAVA_HOME"]).expanduser() if env.get("JAVA_HOME") else None
    java = _executable(java_home / "bin/java") if java_home else which("java")
    # The macOS /usr/bin/java trampoline is not a selected JDK installation.
    if not java_home and (not java or java == "/usr/bin/java"):
        java_home = next((p for p in DEFAULT_JAVA_HOMES if _executable(p / "bin/java")), None)
        java = _executable(java_home / "bin/java") if java_home else java
    if java and not java_home:
        java_home = Path(java).resolve().parent.parent

    def android_tool(relative: str) -> str | None:
        return _executable(android / relative) if android else which(Path(relative).name)

    return Tools(
        flutter=flutter, dart=dart, java=java,
        adb=android_tool("platform-tools/adb"),
        emulator=android_tool("emulator/emulator"),
        sdkmanager=android_tool("cmdline-tools/latest/bin/sdkmanager"),
        avdmanager=android_tool("cmdline-tools/latest/bin/avdmanager"),
        node=which("node"), python=sys.executable, openssl=which("openssl"),
        codex=which("codex"), brew=which("brew"),
        android_home=android, java_home=java_home,
    )


def tool_env(tools: Tools) -> dict[str, str]:
    env = project_environment()
    bins = [str(Path(p).parent) for p in (
        tools.flutter, tools.dart, tools.java, tools.adb, tools.sdkmanager,
        tools.emulator, tools.node, tools.openssl,
    ) if p]
    env["PATH"] = os.pathsep.join(dict.fromkeys([*bins, env.get("PATH", "")]))
    if tools.java_home:
        env["JAVA_HOME"] = str(tools.java_home)
    if tools.android_home:
        env["ANDROID_HOME"] = env["ANDROID_SDK_ROOT"] = str(tools.android_home)
    if tools.flutter:
        env["FLUTTER_ROOT"] = str(Path(tools.flutter).resolve().parent.parent)
    return env


def _run(
    command: Sequence[str], *, tools: Tools | None = None, cwd: Path = ROOT,
    timeout: int = 60, dry_run: bool = False, quiet: bool = False,
    input_text: str | None = None,
) -> subprocess.CompletedProcess[str]:
    if not quiet:
        print(f"$ {shlex.join(command)}", flush=True)
    if dry_run:
        return subprocess.CompletedProcess(command, 0, "", "")
    try:
        result = subprocess.run(
            list(command), cwd=cwd, check=False, capture_output=True, text=True,
            timeout=timeout, env=tool_env(tools) if tools else None,
            input=input_text, stdin=None if input_text is not None else subprocess.DEVNULL,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise BootstrapError(f"{shlex.join(command)}: {error}") from error
    if not quiet:
        if result.stdout.strip():
            print(result.stdout.rstrip())
        if result.stderr.strip():
            print(result.stderr.rstrip(), file=sys.stderr)
    if result.returncode:
        detail = (result.stderr or result.stdout).strip()[-2000:]
        raise BootstrapError(f"exit {result.returncode}: {shlex.join(command)}\n{detail}")
    return result


def _output(command: Sequence[str], **kwargs) -> str:
    result = _run(command, quiet=True, **kwargs)
    return (result.stdout + "\n" + result.stderr).strip()


def parse_flutter_version(output: str) -> str | None:
    match = re.search(r"Flutter\s+(\d+\.\d+\.\d+)", output)
    return match.group(1) if match else None


def parse_dart_version(output: str) -> str | None:
    match = re.search(r"Dart SDK version:\s*(\d+\.\d+\.\d+)", output)
    return match.group(1) if match else None


def baseline_diagnostics(tools: Tools) -> list[Diagnostic]:
    checks = []
    versions = (
        ("Flutter", tools.flutter, ["--version"], EXPECTED_FLUTTER, parse_flutter_version),
        ("Dart", tools.dart, ["--version"], EXPECTED_DART, parse_dart_version),
        ("JDK", tools.java, ["-version"], "21", lambda s: _major(s)),
        ("Node.js", tools.node, ["--version"], None, lambda s: s.splitlines()[0]),
        ("Python", tools.python, ["--version"], None, lambda s: s.splitlines()[0]),
        ("OpenSSL", tools.openssl, ["version"], None, lambda s: s.splitlines()[0]),
        ("ADB", tools.adb, ["version"], None, lambda s: s.splitlines()[0]),
        ("Android Emulator", tools.emulator, ["-version"], None, lambda s: s.splitlines()[0]),
        ("sdkmanager", tools.sdkmanager, ["--version"], None, lambda s: s.splitlines()[0]),
    )
    for name, path, arguments, expected, parse in versions:
        if not path:
            checks.append(Diagnostic("FAIL", name, "missing; configure SDK paths or run make setup-system"))
            continue
        try:
            value = parse(_output([path, *arguments], tools=tools))
            passed = value is not None and (expected is None or value == expected)
            checks.append(Diagnostic(
                "PASS" if passed else "FAIL", name,
                f"{value} ({path})" if passed else f"{value}; expected {expected} ({path})",
            ))
        except (BootstrapError, IndexError) as error:
            checks.append(Diagnostic("FAIL", name, str(error)))
    for name, relative in (
        ("Android Platform 36", "platforms/android-36/android.jar"),
        ("Android Build Tools 36.0.0", "build-tools/36.0.0/source.properties"),
        ("Android NDK 28.2.13676358", f"ndk/{EXPECTED_NDK}/source.properties"),
    ):
        path = tools.android_home / relative if tools.android_home else None
        checks.append(Diagnostic("PASS" if path and path.is_file() else "FAIL", name, str(path or "Android SDK missing")))
    return checks


def _major(output: str) -> str | None:
    match = re.search(r'(?:version\s+|openjdk\s+|java\s+)["\']?(\d+)', output, re.I)
    return match.group(1) if match else None


def _pigeon_diagnostics(tools: Tools) -> list[Diagnostic]:
    """Run the locked generator directly, with every output redirected to tmp.

    No `dart run`/pub resolution and no symlinks into writable project caches.
    This also checks a dirty source tree independently of Git HEAD.
    """
    config = ROOT / ".dart_tool/package_config.json"
    if not tools.dart or not config.is_file():
        return [Diagnostic("FAIL", "Pigeon generation", "run make setup first")]
    try:
        packages = json.loads(config.read_text())["packages"]
        package = next(p for p in packages if p["name"] == "pigeon")
        uri = urlparse(urljoin(config.as_uri(), package["rootUri"]))
        if uri.scheme != "file":
            raise BootstrapError("Pigeon package is not a local file URI")
        entry = Path(unquote(uri.path)) / "bin/pigeon.dart"
        with tempfile.TemporaryDirectory(prefix="site-lens-pigeon-") as temporary:
            temporary_root = Path(temporary)
            _run([
                tools.dart, f"--packages={config}", str(entry),
                "--input", str(ROOT / "pigeons/web_host.dart"),
                "--base_path", temporary, "--package_name", "site_lens",
            ], cwd=temporary_root, tools=tools, timeout=180, quiet=True)
            different = [relative for relative in PIGEON_GENERATED if (
                not (ROOT / relative).is_file()
                or not (temporary_root / relative).is_file()
                or (temporary_root / relative).read_bytes() != (ROOT / relative).read_bytes()
            )]
        if different:
            return [Diagnostic("FAIL", "Pigeon generation", "stale or missing: " + ", ".join(different))]
        return [Diagnostic("PASS", "Pigeon generation", "bindings match current source with the installed generator")]
    except (BootstrapError, OSError, ValueError, KeyError, StopIteration) as error:
        return [Diagnostic("FAIL", "Pigeon generation", str(error))]


def print_diagnostics(checks: Sequence[Diagnostic]) -> int:
    for check in checks:
        print(f"[{check.status}] {check.name}: {check.detail}", flush=True)
    failures = sum(check.status == "FAIL" for check in checks)
    print(f"doctor: {failures} required check(s) failed" if failures else "doctor: required checks passed; review warnings")
    return 1 if failures else 0


def collect_diagnostics(tools: Tools) -> list[Diagnostic]:
    checks = configuration_diagnostics() + baseline_diagnostics(tools)
    checks.extend(_pigeon_diagnostics(tools))
    for name, command in (
        ("Dart MCP", [tools.dart, "mcp-server", "--version"]),
        ("ADB devices", [tools.adb, "devices", "-l"]),
        ("Android AVDs", [tools.emulator, "-list-avds"]),
    ):
        if not command[0]:
            checks.append(Diagnostic("WARN", name, "tool missing"))
            continue
        try:
            output = _output(command, tools=tools)
            checks.append(Diagnostic("PASS" if output else "WARN", name, output or "none configured"))
        except BootstrapError as error:
            checks.append(Diagnostic("WARN", name, str(error)))
    if tools.codex:
        try:
            record = plugin_record(tools)
            active = record and record.get("installed") is True and record.get("enabled") is True
            checks.append(Diagnostic("PASS" if active else "WARN", "Codex plugin", PLUGIN_ID if active else "run make setup-agent"))
        except BootstrapError as error:
            checks.append(Diagnostic("WARN", "Codex plugin", str(error)))
    else:
        checks.append(Diagnostic("WARN", "Codex CLI", "install Codex before make setup-agent"))
    parent_path = os.environ.get("SITE_LENS_PARENT_PATH", os.environ.get("PATH", ""))
    dart_on_path = shutil.which("dart", path=parent_path)
    checks.append(Diagnostic("PASS" if dart_on_path else "WARN", "Dart on Codex PATH", dart_on_path or "run make setup-agent; its MCP command needs `dart` on PATH"))
    try:
        status = _output(["git", "status", "--porcelain"])
        checks.append(Diagnostic("WARN" if status else "PASS", "Git worktree", f"{len(status.splitlines())} changed path(s), preserved" if status else "clean"))
    except BootstrapError as error:
        checks.append(Diagnostic("WARN", "Git worktree", str(error)))
    signer = Path(project_environment().get("SITE_LENS_SIGNING_PROPERTIES") or str(Path.home() / ".config/site-lens/signing.properties")).expanduser()
    checks.append(Diagnostic("PASS" if signer.is_file() else "WARN", "Release signing", "configured" if signer.is_file() else "missing; only required by make build-release"))
    return checks


def project_setup(*, dry_run: bool = False) -> int:
    tools = resolve_tools()
    failures = [c for c in baseline_diagnostics(tools) if c.status == "FAIL"]
    if failures:
        print_diagnostics(failures)
        raise BootstrapError("development baseline incomplete; configure SDK paths and run make doctor")
    # Regeneration may overwrite generated bindings, but never existing local edits.
    dirty = _output(["git", "status", "--porcelain", "--", *PIGEON_GENERATED])
    if dirty:
        raise BootstrapError("Pigeon outputs have local edits; preserve them before make setup")
    _run([tools.flutter, "pub", "get", "--enforce-lockfile"], tools=tools, timeout=600, dry_run=dry_run)
    _run([tools.dart, "run", "pigeon", "--input", "pigeons/web_host.dart"], tools=tools, timeout=180, dry_run=dry_run)
    print("project setup complete" if not dry_run else "project setup preview complete")
    print("next: make doctor && make check; make emulator-check EMULATOR_AVD=<avd-name>; make acceptance DEVICE=<adb-serial>")
    return 0


def _brew_installed(brew: str, kind: str, name: str) -> bool:
    try:
        _output([brew, "list", f"--{kind}", name])
        return True
    except BootstrapError:
        return False


def system_setup(*, dry_run: bool = False) -> int:
    if platform.system() != "Darwin":
        raise BootstrapError("setup-system supports macOS only; install the documented tools manually on other hosts")
    tools = resolve_tools()
    if not tools.brew:
        raise BootstrapError("Homebrew missing; install Homebrew first, then rerun make setup-system")
    for kind, name in (
        ("formula", "openjdk@21"), ("formula", "node"),
        ("formula", "openssl@3"), ("formula", "python"),
        ("cask", "android-commandlinetools"),
    ):
        if _brew_installed(tools.brew, kind, name):
            print(f"[PASS] Homebrew {name}: installed")
        else:
            _run([tools.brew, "install", f"--{kind}", name], dry_run=dry_run, timeout=1800)
    prefix = Path(_output([tools.brew, "--prefix"]))
    # Respect overrides while locating new keg-only tools before the next shell starts.
    env = project_environment()
    if not env.get("JAVA_HOME"):
        env["JAVA_HOME"] = str(prefix / "opt/openjdk@21/libexec/openjdk.jdk/Contents/Home")
    if not (env.get("ANDROID_HOME") or env.get("ANDROID_SDK_ROOT")):
        env["ANDROID_HOME"] = str(tools.android_home or prefix / "share/android-commandlinetools")
    tools = resolve_tools(env)
    sdkmanager = tools.sdkmanager or str(prefix / "share/android-commandlinetools/cmdline-tools/latest/bin/sdkmanager")
    android = tools.android_home or Path(env.get("ANDROID_HOME") or env.get("ANDROID_SDK_ROOT") or prefix / "share/android-commandlinetools")
    _run([sdkmanager, f"--sdk_root={android}", "--install", *SYSTEM_SDK_PACKAGES], tools=tools, dry_run=dry_run, timeout=1800)

    if not tools.flutter:
        target = DEFAULT_FLUTTER_BIN_DIR.parent
        if target.exists():
            raise BootstrapError(f"Flutter directory exists but is incomplete: {target}; select a valid FLUTTER_ROOT")
        if not dry_run:
            target.parent.mkdir(parents=True, exist_ok=True)
        _run(["git", "clone", "--filter=blob:none", "--no-checkout", "https://github.com/flutter/flutter.git", str(target)], dry_run=dry_run, timeout=1800)
        _run(["git", "-C", str(target), "checkout", FLUTTER_REVISION], dry_run=dry_run, timeout=1800)
        print(f"Flutter installed at {target}; set FLUTTER_ROOT if your shell does not discover it")

    avd_name = env.get("AVD_NAME", "").strip()
    if avd_name:
        if not re.fullmatch(r"[A-Za-z0-9_.-]+", avd_name):
            raise BootstrapError("AVD_NAME must contain only letters, digits, underscore, dot, or hyphen")
        avdmanager = tools.avdmanager or str(prefix / "share/android-commandlinetools/cmdline-tools/latest/bin/avdmanager")
        if dry_run:
            existing = ""
        else:
            existing = _output([avdmanager, "list", "avd"], tools=tools)
        if re.search(rf"^\s*Name:\s*{re.escape(avd_name)}\s*$", existing, re.MULTILINE):
            print(f"[PASS] AVD {avd_name}: already exists; preserved")
        else:
            abi = "arm64-v8a" if platform.machine() == "arm64" else "x86_64"
            image = env.get("AVD_IMAGE") or f"system-images;android-36;google_apis;{abi}"
            _run([sdkmanager, f"--sdk_root={android}", "--install", image], tools=tools, dry_run=dry_run, timeout=1800)
            _run([avdmanager, "create", "avd", "--name", avd_name, "--package", image, "--device", "pixel_6"], tools=tools, dry_run=dry_run, input_text="no\n")
    else:
        print("AVD creation skipped; set AVD_NAME=<name> explicitly to create one")
    print("system setup complete" if not dry_run else "system setup preview complete")
    recommended_java = prefix / "opt/openjdk@21/libexec/openjdk.jdk/Contents/Home"
    print(f"next: JAVA_HOME={shlex.quote(str(recommended_java))} ANDROID_HOME={shlex.quote(str(android))} make setup")
    print(f"If SDK licenses are missing, review them with: {shlex.quote(sdkmanager)} --sdk_root={shlex.quote(str(android))} --licenses")
    return 0


def plugin_record(tools: Tools) -> dict | None:
    output = _output([tools.codex, "plugin", "list", "--marketplace", "dart-flutter", "--json"], tools=tools)
    try:
        data = json.loads(output)
        return next((p for p in data["installed"] if p.get("pluginId") == PLUGIN_ID), None)
    except (ValueError, KeyError, TypeError) as error:
        raise BootstrapError("unexpected codex plugin list JSON; update Codex and retry") from error


def _agent_path(tools: Tools, *, dry_run: bool) -> None:
    """Expose the selected SDK to the existing plugin's `dart` command.

    Install missing links only in a user-owned PATH directory; never replace an
    existing command, alter shell profiles, or add a duplicate MCP registration.
    """
    parent_path = os.environ.get("SITE_LENS_PARENT_PATH", os.environ.get("PATH", ""))
    local_bin = Path.home() / ".local/bin"
    for name, target in (("dart", tools.dart), ("flutter", tools.flutter)):
        found = shutil.which(name, path=parent_path)
        if found:
            continue
        if str(local_bin) not in parent_path.split(os.pathsep):
            raise BootstrapError(f"add {Path(tools.dart).parent} to Codex's PATH before setup-agent; e.g. export PATH={shlex.quote(str(Path(tools.dart).parent))}:\"$PATH\"")
        link = local_bin / name
        if link.exists() or link.is_symlink():
            raise BootstrapError(f"{link} already exists and is unusable; repair it explicitly")
        print(f"link {link} -> {target}")
        if not dry_run:
            local_bin.mkdir(parents=True, exist_ok=True)
            link.symlink_to(target)


def agent_setup(*, dry_run: bool = False) -> int:
    tools = resolve_tools()
    if not tools.codex or not tools.dart or not tools.flutter:
        raise BootstrapError("Codex CLI and fixed Flutter/Dart SDK are required for setup-agent")
    _agent_path(tools, dry_run=dry_run)
    # Marketplace/plugin lists are read first; unrelated failures are never treated as success.
    marketplaces = json.loads(_output([tools.codex, "plugin", "marketplace", "list", "--json"], tools=tools))
    existing = next((m for m in marketplaces["marketplaces"] if m.get("name") == "dart-flutter"), None)
    if existing:
        source = existing.get("marketplaceSource", {}).get("source", "")
        if source.rstrip("/").removesuffix(".git") != "https://github.com/flutter/agent-plugins":
            raise BootstrapError("marketplace dart-flutter exists with a different source; reconcile it explicitly")
    else:
        _run([tools.codex, "plugin", "marketplace", "add", "flutter/agent-plugins"], tools=tools, dry_run=dry_run)
    record = plugin_record(tools)
    if not record or record.get("installed") is not True or record.get("enabled") is not True:
        _run([tools.codex, "plugin", "add", PLUGIN_ID], tools=tools, dry_run=dry_run)
    if not dry_run:
        record = plugin_record(tools)
        if not record or record.get("installed") is not True or record.get("enabled") is not True:
            raise BootstrapError("Codex did not confirm the plugin is installed AND enabled")
        print(f"[PASS] Codex {PLUGIN_ID}: installed and enabled ({record.get('version', 'unknown')})")
    _run([tools.dart, "mcp-server", "--version"], tools=tools, dry_run=dry_run)
    print("agent setup complete; restart Codex to load the new tools" if not dry_run else "agent setup preview complete")
    return 0


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("command", choices=("project", "system", "agent", "doctor", "path", "env-value", "validate-env"))
    result.add_argument("path_kind", nargs="?")
    result.add_argument("--dry-run", action="store_true", help="preview writes without executing them")
    result.add_argument("--file", type=Path, help="project environment file")
    result.add_argument("key", nargs="?", help="allowlisted variable for env-value")
    for option in ("flutter-root", "flutter-bin-dir", "android-home", "java-home"):
        result.add_argument(f"--{option}", help="explicit toolchain override for this invocation")
    return result


def main(argv: Sequence[str] | None = None) -> int:
    args = parser().parse_args(argv)
    if args.flutter_root and not args.flutter_bin_dir:
        os.environ.pop("FLUTTER_BIN_DIR", None)
    for name in ("flutter_root", "flutter_bin_dir", "android_home", "java_home"):
        if value := getattr(args, name):
            os.environ[name.upper()] = value
    try:
        if args.command == "env-value":
            key = args.key or args.path_kind
            if not key:
                raise BootstrapError("env-value requires a variable name")
            path = args.file or env_file_path()
            print(env_value(path, key))
            return 0
        if args.command == "validate-env":
            path = args.file or env_file_path()
            parse_env_file(path)
            return 0
        if args.command == "path":
            tools = resolve_tools()
            value = {
                "flutter-bin": str(Path(tools.flutter).parent) if tools.flutter else "",
                "java-home": str(tools.java_home or ""),
                "android-home": str(tools.android_home or ""),
            }.get(args.path_kind)
            if value is None:
                raise BootstrapError("path requires flutter-bin, java-home, or android-home")
            print(value)
            return 0
        if args.command == "doctor":
            return print_diagnostics(collect_diagnostics(resolve_tools()))
        return {"project": project_setup, "system": system_setup, "agent": agent_setup}[args.command](dry_run=args.dry_run)
    except (BootstrapError, OSError, ValueError, KeyError) as error:
        print(f"bootstrap: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
