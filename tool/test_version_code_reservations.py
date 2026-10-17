import unittest

from version_code_reservations import reservation_ref, summarize, tag_slug


class VersionCodeReservationsTest(unittest.TestCase):
    def test_reservation_ref_uses_code_and_release_tag(self):
        self.assertEqual(
            reservation_ref("v0.2.0.alpha4", 21),
            "refs/tags/version-code/21-v0.2.0.alpha4",
        )

    def test_summary_flattens_paginated_refs_and_finds_existing_tag(self):
        result = summarize(
            [
                [{"ref": "refs/tags/version-code/21-v0.2.0.alpha4"}],
                [
                    {"ref": "refs/tags/version-code/20-v0.2.0.alpha3"},
                    {"ref": "refs/tags/not-a-reservation"},
                ],
            ],
            "v0.2.0.alpha4",
        )
        self.assertEqual(result["existing_code"], 21)
        self.assertEqual(result["highest_reserved_version_code"], 21)
        self.assertEqual(len(result["reservations"]), 2)

    def test_multiple_reservations_for_one_tag_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "multiple versionCode reservations"):
            summarize(
                [
                    {"ref": "refs/tags/version-code/21-v0.2.0.alpha4"},
                    {"ref": "refs/tags/version-code/22-v0.2.0.alpha4"},
                ],
                "v0.2.0.alpha4",
            )

    def test_tag_slug_is_safe_for_ref_suffix(self):
        self.assertEqual(tag_slug("v1/2?3"), "v1-2-3")


if __name__ == "__main__":
    unittest.main()
