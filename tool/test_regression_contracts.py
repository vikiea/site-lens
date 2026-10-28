"""Lifecycle failure regressions using temporary repositories; no ADB or network."""

# REGRESSION CONTRACT: RELEASE-001

import contextlib
import copy
import datetime as dt
import io
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import check_regression_contracts as c
import generate_regression_matrix as matrix
import update_regression_contract as update

DATE = dt.date(2026, 10, 28)
VERSION = "0.5.0-alpha11"


class RepositoryContractTests(unittest.TestCase):
    def test_registry_and_bidirectional_bindings(self):
        data = c._read_registry()
        self.assertEqual(c.validate_contracts(data), [])
        self.assertEqual(c.validate_marker_bindings(data, c.discover_markers()), [])

    def test_checked_in_matrix_is_current(self):
        self.assertEqual(matrix.check_output(matrix.render_matrix(matrix.load_registry())), [])

    def test_future_validation_document_requires_status(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            folder = root / "docs/validation"
            folder.mkdir(parents=True)
            future = folder / "v9.9.9.alpha1-check.md"
            future.write_text("# Not yet executed\n")
            with patch.object(c, "ROOT", root):
                self.assertTrue(c.validate_future_validation_docs("0.1.0"))
                future.write_text("文档状态：计划中\n")
                self.assertEqual(c.validate_future_validation_docs("0.1.0"), [])


class FixtureCase(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.registry = self.root / c.REGISTRY_PATH
        self.output = self.root / "docs/validation/regression-matrix.md"
        for folder in ("tool", "lib", "test", "docs/validation"):
            (self.root / folder).mkdir(parents=True, exist_ok=True)
        (self.root / "pubspec.yaml").write_text("version: 0.5.0-alpha11+120\n")
        (self.root / "lib/one.dart").write_text("source\n")
        (self.root / "lib/two.dart").write_text("successor\n")
        self.data = {"schemaVersion": 2, "contracts": [], "history": []}
        for name in ("ONE", "TWO"):
            cid = f"TEST-{name}-001"
            test = f"test/{name.lower()}.dart"
            (self.root / test).write_text("// " + "REGRESSION CONTRACT: " + cid + "\n")
            row = {
                "id": cid, "revision": 1, "status": "active", "owner": "maintainers",
                "description": name, "introducedIn": VERSION, "lastVerified": None,
                "replacedBy": None, "changedPaths": [f"lib/{name.lower()}.dart"],
                "testFiles": [test], "evidence": [{"kind": "test", "ref": test}],
                "validation": "L1", "blocking": True,
            }
            self.data["contracts"].append(row)
            self.data["history"].append({
                "id": cid, "revision": 1, "status": "active", "action": "introduced",
                "date": "2026-08-01", "version": VERSION, "summary": "Initial fixture",
                "stateHash": c.state_hash(row),
                "behaviorHash": c.behavior_hash(row),
            })
        self.patches = [
            patch.object(c, "ROOT", self.root), patch.object(c, "REGISTRY", self.registry),
            patch.object(c, "today", return_value=DATE),
            patch.object(matrix, "ROOT", self.root), patch.object(matrix, "REGISTRY", self.registry),
            patch.object(matrix, "OUTPUT", self.output), patch.object(update, "ROOT", self.root),
            patch.object(update, "REGISTRY", self.registry),
        ]
        for item in self.patches:
            item.start()
            self.addCleanup(item.stop)
        self.save(self.data)

    def save(self, data):
        self.registry.write_text(json.dumps(data))
        self.output.write_text(matrix.render_matrix(data))

    def change(self, data=None, action="update", **kwargs):
        return update.change_contract(
            data if data is not None else self.data, action=action, contract_id="TEST-ONE-001",
            summary="Fixture change", date=kwargs.pop("date", "2026-10-28"),
            version=kwargs.pop("version", VERSION), **kwargs)


class LifecycleTests(FixtureCase):
    def test_valid_fixture(self):
        self.assertEqual(c.validate_contracts(self.data), [])

    def test_malformed_shapes_fail_without_exceptions(self):
        for invalid in (None, [], {}, {"schemaVersion": 2, "contracts": None, "history": []}):
            with self.subTest(invalid=invalid):
                self.assertTrue(c.validate_contracts(invalid))
        for field, invalid in (("id", []), ("status", {}), ("revision", True),
                               ("testFiles", "test/one.dart"), ("changedPaths", [None]),
                               ("evidence", None), ("lastVerified", "today")):
            data = copy.deepcopy(self.data)
            data["contracts"][0][field] = invalid
            with self.subTest(field=field):
                self.assertTrue(c.validate_contracts(data))

    def test_live_contract_cannot_lose_all_tests(self):
        with self.assertRaisesRegex(ValueError, "non-empty testFiles"):
            self.change(definition={"testFiles": []})

    def test_paths_must_be_real_files_and_stay_inside_repository(self):
        for path in ("test", "/tmp/outside.dart", "../one.dart", "./test/one.dart"):
            with self.subTest(path=path), self.assertRaises(ValueError):
                self.change(definition={"testFiles": [path]})
        with tempfile.TemporaryDirectory() as outside:
            target = Path(outside) / "foreign.dart"
            target.write_text("foreign")
            (self.root / "test/link.dart").symlink_to(target)
            with self.assertRaisesRegex(ValueError, "inside repository"):
                self.change(definition={"testFiles": ["test/link.dart"]})

    def test_marker_scan_covers_native_tests_and_ignores_string_literals(self):
        native = self.root / "android/app/src/test/Foo.kt"
        native.parent.mkdir(parents=True)
        native.write_text("// " + "REGRESSION CONTRACT: TEST-ONE-001\n")
        (self.root / "tool/example.py").write_text('MARKER = "REGRESSION CONTRACT: UNKNOWN-001"\n')
        markers = c.discover_markers()
        self.assertNotIn("UNKNOWN-001", markers)
        self.assertIn("android/app/src/test/Foo.kt", markers["TEST-ONE-001"])
        self.assertTrue(c.validate_marker_bindings(self.data, markers))
        native.write_text("// " + "REGRESSION CONTRACT: invalid\n")
        with self.assertRaisesRegex(ValueError, "invalid contract marker"):
            c.discover_markers()

    def test_unknown_missing_and_extra_markers_fail(self):
        markers = c.discover_markers()
        markers["UNKNOWN-001"] = {"test/other.dart"}
        markers["TEST-ONE-001"] = {"test/other.dart"}
        errors = c.validate_marker_bindings(self.data, markers)
        self.assertTrue(any("unknown regression" in item for item in errors))
        self.assertTrue(any("missing markers" in item for item in errors))
        self.assertTrue(any("missing from testFiles" in item for item in errors))

    def test_metadata_change_without_history_fails(self):
        data = copy.deepcopy(self.data)
        data["contracts"][0]["description"] = "silent change"
        self.assertTrue(any("latest history" in item for item in c.validate_contracts(data)))

    def test_history_revisions_and_dates_cannot_move_backwards(self):
        data = self.change(definition={"owner": "another"})
        for field, value in (("revision", 1), ("date", "2026-07-01")):
            bad = copy.deepcopy(data)
            bad["history"][-1][field] = value
            self.assertTrue(c.validate_contracts(bad))

    def test_replacement_must_be_active_not_self_missing_or_cyclic(self):
        for target in ("TEST-ONE-001", "MISSING-001"):
            with self.subTest(target=target), self.assertRaisesRegex(ValueError, "active contract"):
                self.change(action="deprecate", replaced_by=target)
        data = self.change(action="deprecate", replaced_by="TEST-TWO-001")
        with self.assertRaisesRegex(ValueError, "active contract"):
            update.change_contract(
                data, action="deprecate", contract_id="TEST-TWO-001",
                replaced_by="TEST-ONE-001", summary="cycle", date="2026-10-28", version=VERSION)

    def test_revocation_retains_tombstone_and_does_not_block_future_source_edits(self):
        data = self.change(action="deprecate", replaced_by="TEST-TWO-001", date="2026-09-28")
        revoked = self.change(data, action="revoke", date="2026-09-28")
        self.assertFalse(revoked["contracts"][0]["blocking"])
        self.assertEqual(revoked["contracts"][0]["testFiles"], [])
        self.assertTrue(c.validate_marker_bindings(revoked, c.discover_markers()))
        (self.root / "test/one.dart").unlink()
        (self.root / "lib/one.dart").unlink()
        self.assertEqual(c.validate_contracts(revoked), [])
        self.assertEqual(c.validate_marker_bindings(revoked, c.discover_markers()), [])
        self.assertNotIn("TEST-ONE-001", c.impacted_contracts(revoked, {"lib/one.dart"}))
        with self.assertRaisesRegex(ValueError, "immutable"):
            self.change(revoked, definition={"owner": "other"})

    def test_active_can_be_revoked_with_reason_without_a_waiting_period(self):
        data = self.change(action="revoke")
        self.assertEqual(data["contracts"][0]["status"], "revoked")
        self.assertEqual(data["history"][-1]["action"], "revoked")
        with self.assertRaisesRegex(ValueError, "reason"):
            update.change_contract(self.data, action="revoke", contract_id="TEST-ONE-001",
                                   summary="", date="2026-10-28", version=VERSION)

    def test_reactivation_cannot_be_disguised_as_metadata_update(self):
        data = self.change(action="deprecate", replaced_by="TEST-TWO-001")
        row = data["contracts"][0]
        row.update(status="active", replacedBy=None, revision=row["revision"] + 1)
        event = dict(data["history"][-1])
        event.update(action="updated", status="active", revision=row["revision"],
                     stateHash=c.state_hash(row), behaviorHash=c.behavior_hash(row))
        data["history"].append(event)
        self.assertTrue(any("invalid updated" in item for item in c.validate_contracts(data)))

    def test_future_dates_and_bad_version_cannot_mutate_contracts(self):
        for kwargs in ({"date": "2026-10-29"}, {"version": "garbage"}):
            with self.subTest(kwargs=kwargs), self.assertRaises(ValueError):
                self.change(definition={"owner": "other"}, **kwargs)

    def test_revoked_historical_replacement_does_not_freeze_successor(self):
        data = self.change(action="deprecate", replaced_by="TEST-TWO-001", date="2026-08-02")
        data = self.change(data, action="revoke", date="2026-09-01")
        definition = {key: value for key, value in data["contracts"][1].items() if key in update.EDITABLE}
        definition["id"] = "TEST-THREE-001"
        data = update.change_contract(data, action="add", definition=definition, summary="Next successor",
                                      date="2026-09-02", version=VERSION)
        changed = update.change_contract(data, action="deprecate", contract_id="TEST-TWO-001",
                                         replaced_by="TEST-THREE-001", summary="Migrate again",
                                         date="2026-10-01", version=VERSION)
        self.assertEqual(c.validate_contracts(changed), [])
        self.assertEqual(c.validate_registry_changes(data, changed), [])

    def test_verification_event_cannot_hide_behavior_change(self):
        report = "docs/validation/verified.md"
        (self.root / report).write_text("Completed checks")
        data = self.change(action="verify", report=report, level="L1")
        row = data["contracts"][0]
        row["description"] = "new behavior without clearing evidence"
        data["history"][-1].update(stateHash=c.state_hash(row), behaviorHash=c.behavior_hash(row))
        self.assertTrue(any("verification cannot change" in item for item in c.validate_contracts(data)))

    def test_history_rewrite_and_contract_deletion_fail_against_base(self):
        data = self.change(definition={"owner": "another"})
        data["history"][0]["summary"] = "rewritten"
        self.assertTrue(any("append-only" in item for item in c.validate_registry_changes(self.data, data)))
        removed = copy.deepcopy(self.data)
        removed["contracts"].pop(0)
        removed["history"] = [e for e in removed["history"] if e["id"] != "TEST-ONE-001"]
        self.assertEqual(c.validate_contracts(removed), [])
        self.assertTrue(any("cannot be deleted" in item for item in c.validate_registry_changes(self.data, removed)))

    def test_legacy_schema_migration_cannot_drop_a_contract(self):
        previous = {"schemaVersion": 1, "contracts": [{"id": "LEGACY-001"}]}
        self.assertTrue(c.validate_registry_changes(previous, self.data))

    def test_verification_requires_report_and_is_cleared_by_change(self):
        report = self.root / "docs/validation/check.md"
        with self.assertRaisesRegex(ValueError, "report"):
            self.change(action="verify", report="docs/validation/check.md", level="L1")
        report.write_text("Completed local validation; no device acceptance.\n")
        verified = self.change(action="verify", report="docs/validation/check.md", level="L1")
        self.assertEqual(verified["contracts"][0]["lastVerified"]["level"], "L1")
        changed = self.change(verified, definition={"description": "new invariant"})
        self.assertIsNone(changed["contracts"][0]["lastVerified"])

    def test_failed_mutation_leaves_input_untouched(self):
        original = copy.deepcopy(self.data)
        with self.assertRaises(ValueError):
            self.change(definition={"owner": "new"}, version="garbage")
        self.assertEqual(self.data, original)

    def test_cli_updates_history_and_matrix_together(self):
        definition = self.root / "change.json"
        definition.write_text(json.dumps({"owner": "another"}))
        with contextlib.redirect_stdout(io.StringIO()):
            code = update.main(["update", "--id", "TEST-ONE-001", "--definition", str(definition),
                                "--summary", "Move ownership"])
        self.assertEqual(code, 0)
        stored = json.loads(self.registry.read_text())
        self.assertEqual(stored["contracts"][0]["revision"], 2)
        self.assertEqual(self.output.read_text(), matrix.render_matrix(stored))

    def test_cli_missing_marker_is_rejected_without_writes(self):
        (self.root / "test/one.dart").write_text("missing marker")
        original = (self.registry.read_bytes(), self.output.read_bytes())
        definition = self.root / "change.json"
        definition.write_text(json.dumps({"owner": "another"}))
        with contextlib.redirect_stderr(io.StringIO()):
            code = update.main(["update", "--id", "TEST-ONE-001", "--definition", str(definition),
                                "--summary", "Move ownership"])
        self.assertEqual(code, 1)
        self.assertEqual(original, (self.registry.read_bytes(), self.output.read_bytes()))

    def test_cli_updates_renamed_source_test_and_evidence_paths(self):
        (self.root / "lib/one.dart").rename(self.root / "lib/renamed.dart")
        (self.root / "test/one.dart").rename(self.root / "test/renamed.dart")
        definition = self.root / "renamed.json"
        definition.write_text(json.dumps({
            "changedPaths": ["lib/renamed.dart"], "testFiles": ["test/renamed.dart"],
            "evidence": [{"kind": "test", "ref": "test/renamed.dart"}],
        }))
        with contextlib.redirect_stdout(io.StringIO()):
            code = update.main(["update", "--id", "TEST-ONE-001", "--definition", str(definition),
                                "--summary", "Rename implementation and regression test"])
        self.assertEqual(code, 0)
        stored = json.loads(self.registry.read_text())
        self.assertEqual(c.validate_contracts(stored), [])
        self.assertEqual(c.validate_marker_bindings(stored, c.discover_markers()), [])
        self.assertEqual(stored["contracts"][0]["revision"], 2)
        self.assertEqual(self.output.read_text(), matrix.render_matrix(stored))

    def test_cli_cannot_leave_dangling_paths_after_rename(self):
        (self.root / "lib/one.dart").rename(self.root / "lib/renamed.dart")
        original = (self.registry.read_bytes(), self.output.read_bytes())
        definition = self.root / "incomplete.json"
        definition.write_text(json.dumps({"owner": "new owner"}))
        with contextlib.redirect_stderr(io.StringIO()):
            code = update.main(["update", "--id", "TEST-ONE-001", "--definition", str(definition),
                                "--summary", "Incomplete rename"])
        self.assertEqual(code, 1)
        self.assertEqual(original, (self.registry.read_bytes(), self.output.read_bytes()))

    def test_add_requires_new_id_and_real_binding(self):
        definition = {key: value for key, value in self.data["contracts"][0].items()
                      if key in update.EDITABLE}
        definition["id"] = "NEW-001"
        added = update.change_contract(self.data, action="add", definition=definition,
                                       summary="New behavior", date="2026-10-28", version=VERSION)
        self.assertEqual(added["history"][-1]["action"], "introduced")
        self.assertTrue(c.validate_marker_bindings(added, c.discover_markers()))
        with self.assertRaisesRegex(ValueError, "unique"):
            update.change_contract(added, action="add", definition=definition,
                                   summary="Duplicate", date="2026-10-28", version=VERSION)

    def test_failed_matrix_publish_restores_registry(self):
        candidate = self.change(definition={"owner": "another"})
        original = (self.registry.read_bytes(), self.output.read_bytes())
        replace = os.replace

        def fail_matrix(source, target):
            if Path(target) == self.output:
                raise OSError("matrix not writable")
            return replace(source, target)

        with patch.object(update.os, "replace", side_effect=fail_matrix):
            with self.assertRaises(OSError):
                update.write_registry(candidate)
        self.assertEqual(original, (self.registry.read_bytes(), self.output.read_bytes()))
        self.assertEqual(list(self.registry.parent.glob(".regression_contracts.json-*")), [])

    def test_matrix_stale_and_malformed_registry_fail_without_writes(self):
        original = self.output.read_bytes()
        self.output.write_text("stale")
        self.assertTrue(matrix.check_output(matrix.render_matrix(self.data)))
        self.output.write_bytes(original)
        self.registry.write_text('{"schemaVersion": 2}')
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(matrix.main(["--write"]), 1)
        self.assertEqual(self.output.read_bytes(), original)

    def test_matrix_escapes_authored_table_content(self):
        data = copy.deepcopy(self.data)
        data["contracts"][0]["owner"] = "name|another\nline<end>"
        rendered = matrix.render_matrix(data)
        self.assertIn(r"name\|another<br>line&lt;end&gt;", rendered)

    def test_impact_retains_old_mapping_for_renamed_paths(self):
        data = copy.deepcopy(self.data)
        data["contracts"][0]["changedPaths"] = ["lib/new.dart"]
        self.assertIn("TEST-ONE-001", c.impacted_contracts(data, {"lib/one.dart"}, self.data))


class GitComparisonTests(FixtureCase):
    def setUp(self):
        super().setUp()
        environment = {key: value for key, value in os.environ.items()
                       if not key.startswith("GITHUB_") and key != "REGRESSION_CONTRACT_BASE"}
        self.environment = patch.dict(os.environ, environment, clear=True)
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.command("init", "-q")
        self.command("config", "user.email", "test@example.invalid")
        self.command("config", "user.name", "Contract Test")
        self.command("add", ".")
        self.command("commit", "-qm", "initial")
        self.base = self.command("rev-parse", "HEAD").strip()

    def command(self, *args):
        return subprocess.run(["git", *args], cwd=self.root, check=True,
                              capture_output=True, text=True).stdout

    def next_commit(self):
        data = self.change(definition={"owner": "second"})
        self.save(data)
        self.command("add", ".")
        self.command("commit", "-qm", "update")

    def event(self, name, payload):
        path = self.root / ".git/event.json"
        path.write_text(json.dumps(payload))
        return patch.dict(os.environ, {"GITHUB_EVENT_NAME": name, "GITHUB_EVENT_PATH": str(path)})

    def test_invalid_base_is_not_silently_ignored(self):
        with self.assertRaisesRegex(ValueError, "history is required"):
            c.comparison_base("does-not-exist")

    def test_push_compares_event_before_even_in_clean_checkout(self):
        self.next_commit()
        with self.event("push", {"before": self.base}):
            base, mode = c.comparison_base()
        self.assertEqual((base, mode), (self.base, "push"))
        self.assertEqual(c.validate_registry_changes(c.registry_at(base), json.loads(self.registry.read_text())), [])

    def test_pull_request_uses_merge_base(self):
        self.next_commit()
        with self.event("pull_request", {"pull_request": {"base": {"sha": self.base}}}):
            self.assertEqual(c.comparison_base(), (self.base, "pull_request"))

    def test_new_tag_and_dispatch_use_parent(self):
        self.next_commit()
        with self.event("push", {"before": "0" * 40}):
            self.assertEqual(c.comparison_base(), (self.base, "parent"))
        with patch.dict(os.environ, {"GITHUB_EVENT_NAME": "workflow_dispatch"}):
            self.assertEqual(c.comparison_base(), (self.base, "parent"))

    def test_github_missing_event_or_sha_fails_closed(self):
        with patch.dict(os.environ, {"GITHUB_EVENT_NAME": "push"}):
            with self.assertRaises(ValueError):
                c.comparison_base()
        with self.event("push", {"before": "f" * 40}):
            with self.assertRaises(ValueError):
                c.comparison_base()
        with self.event("push", {}):
            with self.assertRaises(ValueError):
                c.comparison_base()

    def test_manual_ci_run_still_compares_parent_when_build_changes_files(self):
        self.next_commit()
        (self.root / "lib/one.dart").write_text("build modified tracked file")
        with patch.dict(os.environ, {"GITHUB_EVENT_NAME": "workflow_dispatch"}):
            self.assertEqual(c.comparison_base(), (self.base, "parent"))

    def test_staged_unstaged_untracked_and_rename_paths(self):
        (self.root / "lib/one.dart").rename(self.root / "lib/renamed.dart")
        self.command("add", ".")
        (self.root / "lib/two.dart").write_text("unstaged")
        (self.root / "test/空 格.dart").write_text("new")
        paths = c.changed_paths()
        self.assertTrue({"lib/one.dart", "lib/renamed.dart", "lib/two.dart", "test/空 格.dart"} <= paths)
        self.assertEqual(c.comparison_base(), (self.base, "worktree"))

    def test_index_change_is_visible_even_when_worktree_matches_head(self):
        path = self.root / "lib/one.dart"
        original = path.read_text()
        path.write_text("staged modification")
        self.command("add", "lib/one.dart")
        path.write_text(original)
        self.assertEqual(self.command("diff", "HEAD", "--", "lib/one.dart"), "")
        self.assertIn("lib/one.dart", c.changed_paths())
        self.assertEqual(c.comparison_base(), (self.base, "worktree"))

    def test_shallow_history_failure_is_explicit(self):
        self.next_commit()
        with tempfile.TemporaryDirectory() as folder:
            destination = Path(folder) / "clone"
            subprocess.run(["git", "clone", "-q", "--depth", "1", self.root.as_uri(), str(destination)],
                           check=True, capture_output=True)
            with patch.object(c, "ROOT", destination):
                with self.assertRaisesRegex(ValueError, "shallow"):
                    c.comparison_base()

    def test_changed_paths_include_committed_changes(self):
        self.next_commit()
        paths = c.changed_paths(self.base)
        self.assertIn(c.REGISTRY_PATH, paths)

    def test_registry_deletion_returns_check_failure(self):
        removed = copy.deepcopy(self.data)
        removed["contracts"].pop(0)
        removed["history"] = [event for event in removed["history"] if event["id"] != "TEST-ONE-001"]
        (self.root / "test/one.dart").unlink()
        self.save(removed)
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(c.run(["--base", self.base]), 1)


if __name__ == "__main__":
    unittest.main()
