import unittest

from verify_release_pubspec import verify


class ReleasePubspecTests(unittest.TestCase):
    def test_stable_and_beta_match_tag_and_reserved_code(self):
        for version in ("0.4.0", "0.4.0.alpha16", "0.4.0.beta1", "0.4.0.rc2"):
            source = version.replace(".alpha", "-alpha").replace(".beta", "-beta").replace(".rc", "-rc")
            self.assertEqual(verify(f"version: {source}+94\n", f"v{version}", 94), 94)

    def test_stale_name_is_rejected_in_both_channels(self):
        for tag in ("v0.4.0", "v0.4.0.alpha16"):
            with self.assertRaisesRegex(ValueError, "update it before tagging"):
                verify("version: 0.1.16+28\n", tag)

    def test_reused_reservation_cannot_change_source_version_code(self):
        with self.assertRaisesRegex(ValueError, "reserved versionCode"):
            verify("version: 0.4.0-alpha16+94\n", "v0.4.0.alpha16", 95)

    def test_missing_invalid_or_zero_build_number_is_rejected(self):
        for declaration in ("", "version: 0.4.0", "version: 0.4.0+0"):
            with self.assertRaises(ValueError):
                verify(declaration, "v0.4.0")


if __name__ == "__main__":
    unittest.main()
