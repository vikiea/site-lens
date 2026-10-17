#!/usr/bin/env python3
import unittest

from determine_release_version import (
    Commit,
    infer_bump,
    next_base,
    parse_tag,
    validate_sequence,
)


class ReleaseVersionTest(unittest.TestCase):
    def test_parses_dotted_prerelease_and_sequence(self):
        parsed = parse_tag("v0.2.0.alpha1")
        self.assertEqual(parsed.base, (0, 2, 0))
        self.assertEqual((parsed.kind, parsed.sequence), ("alpha", 1))
        with self.assertRaises(ValueError):
            parse_tag("v0.2.0-alpha1")

    def test_infers_major_minor_patch_and_safe_fallback(self):
        breaking = Commit("a", "feat!: replace storage", "", ("lib/data/database.dart",))
        feature = Commit("b", "feat(browser): add tabs", "", ("lib/ui/screens.dart",))
        patch = Commit("c", "fix(browser): retain tab", "", ("lib/ui/screens.dart",))
        unknown = Commit("d", "update things", "", ("lib/ui/screens.dart",))
        self.assertEqual(infer_bump([breaking])[0], "major")
        self.assertEqual(infer_bump([feature])[0], "minor")
        self.assertEqual(infer_bump([patch])[0], "patch")
        self.assertTrue(infer_bump([unknown])[2])

    def test_cross_domain_capability_is_minor(self):
        commit = Commit(
            "a",
            "support shared browser media controls",
            "",
            ("lib/ui/screens.dart", "lib/media/media_service.dart"),
        )
        self.assertEqual(infer_bump([commit])[0], "minor")

    def test_next_base_and_sequence(self):
        previous = parse_tag("v0.1.5")
        self.assertEqual(next_base(previous, "minor"), (0, 2, 0))
        self.assertEqual(next_base(previous, "patch"), (0, 1, 6))
        current = parse_tag("v0.2.0.alpha2")
        validate_sequence(["v0.2.0.alpha1", "v0.2.0.alpha2"], current)
        with self.assertRaises(ValueError):
            validate_sequence(["v0.2.0.alpha1"], parse_tag("v0.2.0.alpha3"))


if __name__ == "__main__":
    unittest.main()
