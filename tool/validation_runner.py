"""Shared planning, caching, reporting, and execution for Site Lens validation."""

from __future__ import annotations

import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Iterable, Sequence

ROOT = Path(__file__).resolve().parent.parent
LEVELS = ("L0", "L1", "L2", "L3", "L4")
IGNORED_DIRS = {".git", ".dart_tool", "build", "coverage", ".ci_cache"}


class ValidationConfigurationError(ValueError):
    """Raised when a validation request cannot be executed safely."""


class DeviceConnectionError(RuntimeError):
    """Raised when a strict IP:port device preflight fails."""


@dataclass(frozen=True)
class StagePlan:
    name: str
    command: tuple[str, ...] | None = None
    requires_device: bool = False
    cacheable: bool = True
    critical: bool = False


@dataclass
class StageResult:
    name: str
    command: tuple[str, ...] | None
    status: str
    detail: str = ""
    cache_hit: bool = False
    returncode: int | None = None


@dataclass
class ValidationPlan:
    paths: list[str]
    recommended_level: str
    requested_level: str
    reasons: list[str]
    stages: list[StagePlan]
    device: str | None = None
    strict_device: bool = False


@dataclass
class ValidationReport:
    plan: ValidationPlan
    results: list[StageResult] = field(default_factory=list)
    environment: dict[str, str] = field(default_factory=dict)
    device_status: str = "not requested"
    final_status: str = "pending"
    exit_code: int = 0

    def render(self) -> str:
        lines = [
            "# Site Lens validation",
            "",
            f"- Changed paths: {len(self.plan.paths)}",
            f"- Recommended level: `{self.plan.recommended_level}`",
            f"- Requested level: `{self.plan.requested_level}`",
            f"- Device: `{self.plan.device or 'none'}`",
            f"- Device preflight: {self.device_status}",
            "",
            "## Reasons",
        ]
        lines.extend(f"- {reason}" for reason in self.plan.reasons)
        lines.extend(["", "## Stages"])
        if not self.results:
            lines.append("- No executable stages were required.")
        for result in self.results:
            command = " ".join(result.command) if result.command else "(none)"
            cache = "; cache hit" if result.cache_hit else ""
            detail = f" — {result.detail}" if result.detail else ""
            lines.append(
                f"- `{result.status}` **{result.name}**: `{command}`{cache}{detail}"
            )
        lines.extend(["", "## Environment"])
        for key, value in sorted(self.environment.items()):
            lines.append(f"- `{key}`: `{value}`")
        lines.extend(
            [
                "",
                f"**Result:** `{self.final_status}` (exit {self.exit_code})",
            ]
        )
        return "\n".join(lines) + "\n"


def is_tcp_endpoint(device: str) -> bool:
    """Return true for the wireless adb IP:port form used by this project."""
    return ":" in device and not device.startswith("emulator-")


def _normalise_path(path: str) -> str:
    return path.replace("\\", "/").lstrip("./")


def _is_ignored(path: str) -> bool:
    return any(part in IGNORED_DIRS for part in Path(path).parts)


def collect_changed_paths(
    root: Path = ROOT, explicit_paths: Iterable[str] | None = None
) -> list[str]:
    """Collect staged, unstaged, and untracked paths from the current worktree."""
    if explicit_paths is not None:
        paths = [_normalise_path(path) for path in explicit_paths]
    else:
        result = subprocess.run(
            ["git", "status", "--porcelain=v1", "-z"],
            cwd=root,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        raw_entries = result.stdout.decode("utf-8", errors="replace").split("\0")
        paths = []
        index = 0
        while index < len(raw_entries):
            entry = raw_entries[index]
            index += 1
            if not entry:
                continue
            status = entry[:2]
            path = entry[3:]
            paths.append(path)
            if status[0] in "RC" or status[1] in "RC":
                if index < len(raw_entries) and raw_entries[index]:
                    paths.append(raw_entries[index])
                    index += 1
    unique = sorted({_normalise_path(path) for path in paths if not _is_ignored(path)})
    return unique


def _has_any(paths: Sequence[str], *needles: str) -> bool:
    lowered = [path.lower() for path in paths]
    return any(any(needle.lower() in path for needle in needles) for path in lowered)


def _changed_content_signals(paths: Sequence[str], root: Path = ROOT) -> set[str]:
    signals = {
        "webview",
        "window.open",
        "target=_blank",
        "mediasession",
        "foreground service",
        "pigeon",
        "platform channel",
        "methodchannel",
        "navigationdelegate",
        "nativewebhost",
        "platformview",
        "run-as",
    }
    found: set[str] = set()
    for relative in paths:
        path = root / relative
        if not path.is_file() or path.suffix in {".md", ".markdown", ".txt"}:
            continue
        if not (
            relative.startswith(("lib/ui/", "android/", "ios/", "web_assets/"))
            or relative.startswith("pigeons/")
        ):
            continue
        try:
            content = path.read_text(errors="ignore")[:128_000].lower()
        except OSError:
            continue
        found.update(signal for signal in signals if signal in content)
    return found


def classify_paths(paths: Sequence[str], root: Path = ROOT) -> tuple[str, list[str]]:
    """Classify paths conservatively using behavior-first path fallbacks."""
    if not paths:
        return "L1", ["the working tree has no tracked changes; use the normal baseline gate"]

    reasons: list[str] = []
    docs_only = all(
        path.endswith((".md", ".markdown", ".txt"))
        or path in {"AGENTS.md", "README.md"}
        or path.startswith(".agents/skills/")
        for path in paths
    )
    if docs_only:
        return "L0", ["documentation or agent guidance only"]

    release_paths = (
        "android/app/build.gradle",
        "android/app/src/main/AndroidManifest.xml",
        "android/key.properties",
        "ios/Runner.xcodeproj",
        "ios/Runner/Info.plist",
        "ios/Runner/Release.xcconfig",
        ".github/workflows/",
    )
    if _has_any(paths, *release_paths):
        return "L4", ["release, package identity, signing, or CI build configuration changed"]

    full_acceptance_paths = (
        "integration_test/acceptance_suite_test.dart",
        "integration_test/modernization_test.dart",
        "integration_test/evidence_test.dart",
        "tool/run_android_acceptance.py",
        "tool/android_media_actions.py",
        "tool/restore_android_database.py",
        "lib/backup/",
        "lib/device/",
    )
    if _has_any(paths, *full_acceptance_paths):
        return "L3", ["device lifecycle, database restore, media, or full acceptance behavior changed"]

    integration_paths = (
        "integration_test/",
        "pigeons/",
        "lib/web_host/",
        "web_host.g.dart",
        "webhost.g.kt",
        "webhost.g.swift",
        "android/app/src/main/",
        "ios/Runner/NativeWebHost.swift",
        "lib/browser/",
        "lib/scripts/",
        "lib/ui/browser_entry.dart",
        "lib/ui/navigation_observer.dart",
        "lib/background/",
        "lib/ui/app_controller.dart",
        "web_assets/",
    )
    if _has_any(paths, *integration_paths):
        return "L2", ["WebView, navigation, script, Pigeon, native host, or cross-layer behavior changed"]

    signals = _changed_content_signals(paths, root)
    if signals:
        return "L2", [
            "changed content contains cross-layer behavior signals: "
            + ", ".join(sorted(signals))
        ]

    tests_only = all(path.startswith("test/") or path.startswith("tool/test_") for path in paths)
    if tests_only:
        return "L0", ["only focused tests or test tooling changed"]

    source_paths = any(path.startswith(("lib/", "tool/", "web_assets/")) for path in paths)
    if source_paths or _has_any(paths, "pubspec.yaml", "pubspec.lock", "Makefile"):
        return "L1", ["ordinary Dart, tooling, dependency, or service-layer behavior changed"]

    return "L2", ["the changed paths do not match a lower-risk rule; conservative integration level selected"]


def _targeted_commands(paths: Sequence[str]) -> list[StagePlan]:
    commands: list[StagePlan] = []
    dart_tests = [path for path in paths if path.startswith("test/") and path.endswith("_test.dart")]
    dart_sources = [path for path in paths if path.startswith("lib/") and path.endswith(".dart")]
    python_tests = [path for path in paths if path.startswith("tool/test_") and path.endswith(".py")]
    js_contracts = [
        path
        for path in paths
        if path in {"tool/test_runtime.mjs", "tool/test_media_lifecycle.mjs"}
    ]
    userscripts = [path for path in paths if path.endswith(".user.js")]

    if dart_sources:
        commands.append(StagePlan("targeted Dart analysis", ("flutter", "analyze", *dart_sources)))
    if dart_tests:
        commands.append(StagePlan("targeted Flutter tests", ("flutter", "test", *dart_tests)))
    for path in python_tests:
        commands.append(StagePlan(f"Python tool test: {path}", ("python3", path)))
    for path in js_contracts:
        commands.append(StagePlan(f"JavaScript contract: {path}", ("node", path)))
    for path in userscripts:
        commands.append(
            StagePlan(
                f"userscript validation: {path}",
                ("dart", "run", "tool/verify_script.dart", path),
            )
        )
    return commands


def _integration_target(paths: Sequence[str]) -> str | None:
    if _has_any(paths, "lib/browser/", "lib/ui/browser_entry.dart"):
        return "integration_test/browser_tabs_test.dart"
    if _has_any(paths, "lib/scripts/", "pigeons/", "lib/web_host/", "web_assets/userscript_runtime.js"):
        return "integration_test/host_contract_test.dart"
    if _has_any(paths, "lib/background/", "lib/device/", "web_assets/media_lifecycle.js"):
        return "integration_test/modernization_test.dart"
    if _has_any(paths, "integration_test/app_flow_test.dart"):
        return "integration_test/app_flow_test.dart"
    return None


def build_plan(
    paths: Sequence[str],
    requested_level: str | None = None,
    device: str | None = None,
    root: Path = ROOT,
) -> ValidationPlan:
    recommended, reasons = classify_paths(paths, root=root)
    requested = requested_level or recommended
    if requested not in LEVELS:
        raise ValidationConfigurationError(f"invalid level: {requested}; expected L0-L4")
    stages: list[StagePlan] = []
    strict_device = bool(device and is_tcp_endpoint(device))

    if requested == "L0":
        stages.extend(_targeted_commands(paths))
        if not stages:
            stages.append(StagePlan("targeted checks", None))
    elif requested == "L1":
        stages.append(StagePlan("full local check", ("./tool/check.sh",)))
    elif requested == "L2":
        stages.append(StagePlan("full local check", ("./tool/check.sh",)))
        target = _integration_target(paths)
        if device:
            command = ["python3", "tool/run_android_acceptance.py", device, "--skip-check", "--skip-build", "--single-suite"]
            if target:
                command.extend(["--integration-target", target])
            stages.append(
                StagePlan(
                    "targeted Android integration",
                    tuple(command),
                    requires_device=True,
                    cacheable=False,
                    critical=True,
                )
            )
        else:
            stages.append(
                StagePlan(
                    "targeted Android integration",
                    None,
                    requires_device=True,
                    critical=True,
                )
            )
    elif requested == "L3":
        if device:
            stages.append(
                StagePlan(
                    "full Android acceptance",
                    ("make", "acceptance", f"DEVICE={device}"),
                    requires_device=True,
                    cacheable=False,
                    critical=True,
                )
            )
        else:
            stages.append(StagePlan("full local check", ("./tool/check.sh",)))
            stages.append(StagePlan("full Android acceptance", None, requires_device=True, critical=True))
    else:
        if device:
            stages.append(
                StagePlan(
                    "full Android acceptance and formal APK verification",
                    ("make", "acceptance", f"DEVICE={device}"),
                    requires_device=True,
                    cacheable=False,
                    critical=True,
                )
            )
        else:
            stages.append(StagePlan("full local check", ("./tool/check.sh",)))
            stages.append(StagePlan("formal APK verification", ("make", "build-release"), cacheable=False))
            stages.append(StagePlan("full Android acceptance", None, requires_device=True, critical=True))

    return ValidationPlan(
        paths=list(paths),
        recommended_level=recommended,
        requested_level=requested,
        reasons=reasons,
        stages=stages,
        device=device,
        strict_device=strict_device,
    )


def _run_capture(command: Sequence[str], cwd: Path = ROOT) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        list(command),
        cwd=cwd,
        env=runtime_env(),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def runtime_env() -> dict[str, str]:
    value = os.environ.copy()
    flutter = Path.home() / ".local/share/flutter/bin"
    if flutter.is_dir():
        value["PATH"] = f"{flutter}:{value.get('PATH', '')}"
    value.setdefault(
        "JAVA_HOME",
        "/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home",
    )
    value.setdefault("ANDROID_HOME", "/opt/homebrew/share/android-commandlinetools")
    return value


def preflight_device(
    device: str,
    adb_path: str | None = None,
    runner: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
) -> None:
    """Perform one current get-state preflight before any device evidence."""
    adb = adb_path or shutil.which("adb", path=runtime_env().get("PATH"))
    if not adb:
        raise DeviceConnectionError("adb is unavailable; install/configure Android platform tools")
    try:
        result = runner(
            [adb, "-s", device, "get-state"],
            cwd=ROOT,
            env=runtime_env(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=30,
        )
    except subprocess.TimeoutExpired as exc:
        detail = f"adb get-state timed out after {exc.timeout}s"
        if not is_tcp_endpoint(device):
            raise DeviceConnectionError(f"device {device} is not online ({detail})") from exc
        raise DeviceConnectionError(
            f"device {device} is unavailable ({detail}); provide the correct adb port"
        ) from exc
    if result.returncode != 0 or result.stdout.strip() != "device":
        detail = result.stderr.strip() or result.stdout.strip() or "adb get-state failed"
        if not is_tcp_endpoint(device):
            raise DeviceConnectionError(f"device {device} is not online ({detail})")
        raise DeviceConnectionError(
            f"device {device} is unavailable ({detail}); provide the correct adb port"
        )


preflight_tcp_device = preflight_device


def _version(command: Sequence[str]) -> str:
    try:
        result = _run_capture(command)
    except OSError:
        return "unavailable"
    if result.returncode != 0:
        return "unavailable"
    text = (result.stdout or result.stderr).strip().splitlines()
    return text[0][:160] if text else "unknown"


def environment_fingerprint(device: str | None = None) -> dict[str, str]:
    values = {
        "platform": platform.platform(),
        "python": _version((sys.executable, "--version")),
        "flutter": _version(("flutter", "--version")),
        "dart": _version(("dart", "--version")),
        "node": _version(("node", "--version")),
    }
    if device:
        values["device"] = device
        if is_tcp_endpoint(device):
            values["device_mode"] = "ip-port-strict"
    return values


def content_fingerprint(paths: Sequence[str], root: Path = ROOT) -> str:
    digest = hashlib.sha256()
    for relative in sorted(paths):
        path = root / relative
        digest.update(relative.encode())
        digest.update(b"\0")
        if path.is_file():
            digest.update(path.read_bytes())
        elif path.is_dir():
            for child in sorted(child for child in path.rglob("*") if child.is_file()):
                if any(part in IGNORED_DIRS for part in child.relative_to(root).parts):
                    continue
                digest.update(str(child.relative_to(root)).encode())
                digest.update(child.read_bytes())
    return digest.hexdigest()


def worktree_fingerprint(root: Path = ROOT) -> str:
    """Fingerprint the complete worktree state relevant to local validation."""
    digest = hashlib.sha256()
    commands = (
        ["git", "rev-parse", "HEAD"],
        ["git", "diff", "--binary", "HEAD"],
        ["git", "ls-files", "--others", "--exclude-standard", "-z"],
    )
    for command in commands:
        result = subprocess.run(
            command,
            cwd=root,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        digest.update(" ".join(command).encode())
        digest.update(b"\0")
        digest.update(result.stdout)
    untracked = subprocess.run(
        ["git", "ls-files", "--others", "--exclude-standard", "-z"],
        cwd=root,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    ).stdout.decode(errors="replace").split("\0")
    for relative in sorted(path for path in untracked if path):
        path = root / relative
        if path.is_file():
            digest.update(relative.encode())
            digest.update(path.read_bytes())
    return digest.hexdigest()


def cache_key(plan: ValidationPlan, stage: StagePlan, environment: dict[str, str]) -> str:
    payload = {
        "paths": plan.paths,
        "content": content_fingerprint(plan.paths),
        "worktree": worktree_fingerprint(),
        "recommended_level": plan.recommended_level,
        "requested_level": plan.requested_level,
        "stage": stage.name,
        "command": stage.command,
        "environment": environment,
    }
    return hashlib.sha256(json.dumps(payload, sort_keys=True).encode()).hexdigest()


def _cache_path(cache_dir: Path, key: str) -> Path:
    return cache_dir / f"{key}.json"


def _read_cache(cache_dir: Path, key: str) -> dict[str, object] | None:
    path = _cache_path(cache_dir, key)
    try:
        return json.loads(path.read_text())
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return None


def _write_cache(cache_dir: Path, key: str, value: dict[str, object]) -> None:
    cache_dir.mkdir(parents=True, exist_ok=True)
    path = _cache_path(cache_dir, key)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def execute_plan(
    plan: ValidationPlan,
    cache_dir: Path | None = None,
    runner: Callable[[Sequence[str]], subprocess.CompletedProcess[str]] | None = None,
) -> ValidationReport:
    report = ValidationReport(plan=plan, environment=environment_fingerprint(plan.device))
    cache_root = cache_dir or Path(os.environ.get("SITE_LENS_VALIDATION_CACHE", ROOT / ".ci_cache"))

    needs_current_device = any(stage.requires_device for stage in plan.stages) and bool(plan.device)
    device_unavailable = False
    if needs_current_device:
        try:
            preflight_device(plan.device or "")
        except DeviceConnectionError as exc:
            report.device_status = "failed: " + str(exc)
            device_unavailable = True
            if not plan.strict_device:
                report.device_status += "; lower local stages will continue"
            else:
                for stage in plan.stages:
                    report.results.append(
                        StageResult(
                            stage.name,
                            stage.command,
                            "blocked",
                            "strict device preflight failed; command not executed",
                        )
                    )
                report.final_status = "device endpoint unavailable; provide the correct port"
                report.exit_code = 2
                return report
        report.device_status = (
            "passed: single IP:port preflight"
            if plan.strict_device
            else "passed: current device preflight"
        )
    elif any(stage.requires_device for stage in plan.stages):
        if not plan.device:
            report.device_status = "missing: DEVICE is required"
        else:
            report.device_status = "provided; non-IP endpoint"

    missing_device = any(stage.requires_device for stage in plan.stages) and not plan.device

    execute = runner or (lambda command: _run_capture(command))
    for stage in plan.stages:
        if stage.requires_device and (not plan.device or device_unavailable):
            detail = "DEVICE is required" if not plan.device else "current device preflight failed"
            report.results.append(StageResult(stage.name, stage.command, "blocked", detail))
            continue
        if stage.command is None:
            if stage.requires_device:
                report.results.append(
                    StageResult(stage.name, None, "blocked", "required stage has no executable target")
                )
            else:
                report.results.append(StageResult(stage.name, None, "passed", "no executable check required"))
            continue

        key = cache_key(plan, stage, report.environment)
        cached = _read_cache(cache_root, key) if stage.cacheable else None
        if cached and cached.get("status") == "passed" and plan.requested_level in {"L0", "L1", "L2"}:
            report.results.append(
                StageResult(stage.name, stage.command, "passed", "reused exact cached evidence", cache_hit=True, returncode=0)
            )
            continue

        result = execute(stage.command)
        stdout = result.stdout or ""
        stderr = result.stderr or ""
        if stdout:
            print(stdout, end="")
        if stderr:
            print(stderr, end="", file=sys.stderr)
        if result.returncode == 0:
            detail = ""
            if cached and cached.get("status") == "passed":
                detail = "cached evidence available; critical check rerun"
            stage_result = StageResult(stage.name, stage.command, "passed", detail, returncode=0)
            report.results.append(stage_result)
            if stage.cacheable:
                _write_cache(
                    cache_root,
                    key,
                    {"status": "passed", "stage": stage.name, "command": stage.command},
                )
        else:
            report.results.append(
                StageResult(
                    stage.name,
                    stage.command,
                    "failed",
                    "command returned non-zero",
                    returncode=result.returncode,
                )
            )
            report.final_status = "validation failed"
            report.exit_code = 1
            return report

    if missing_device or any(result.status in {"blocked", "failed"} for result in report.results):
        report.final_status = "required validation incomplete"
        report.exit_code = 2
    else:
        report.final_status = "validation passed"
        report.exit_code = 0
    return report
