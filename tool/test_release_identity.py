import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import check_release_identity as identity


class ReleaseIdentityTests(unittest.TestCase):
    # REGRESSION CONTRACT: RELEASE-001
    def test_matching_tag_head_version_and_clean_tree_pass(self):
        with patch.object(identity, "command", side_effect=["abc", "abc", ""]), \
                patch.object(identity, "ROOT", Path(tempfile.mkdtemp())):
            (identity.ROOT / "pubspec.yaml").write_text("version: 0.5.0-alpha11+120\n")
            self.assertEqual(identity.verify("v0.5.0.alpha11", 120), [])

    def test_mismatched_commit_and_dirty_tree_are_failures(self):
        with patch.object(identity, "command", side_effect=["head", "tag", " M file"]), \
                patch.object(identity, "ROOT", Path(tempfile.mkdtemp())):
            (identity.ROOT / "pubspec.yaml").write_text("version: 0.5.0-alpha11+120\n")
            errors = identity.verify("v0.5.0.alpha11", 120)
            self.assertTrue(any("does not match" in error for error in errors))
            self.assertTrue(any("not clean" in error for error in errors))


if __name__ == "__main__":
    unittest.main()
