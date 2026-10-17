import unittest

from determine_version_code import determine


class VersionCodeTest(unittest.TestCase):
    def test_beta_takes_the_next_global_code(self):
        result = determine(
            "v0.2.0.beta1",
            "beta",
            published_codes={"v0.1.9": 7, "v0.2.0.alpha2": 13},
            minimum_code=9,
        )
        self.assertEqual(result["version_code"], 14)

    def test_stable_is_newer_than_an_existing_beta(self):
        result = determine(
            "v0.2.0",
            "stable",
            published_codes={"v0.2.0.beta1": 14},
        )
        self.assertEqual(result["version_code"], 15)

    def test_manual_override_must_clear_the_global_floor(self):
        result = determine(
            "v0.2.1",
            "stable",
            published_codes={"v0.2.0": 15},
            override=20,
        )
        self.assertEqual(result["version_code"], 20)
        with self.assertRaisesRegex(ValueError, "floor"):
            determine(
                "v0.2.1",
                "stable",
                published_codes={"v0.2.0": 15},
                override=15,
            )

    def test_installed_floor_is_honored_without_published_releases(self):
        result = determine("v0.1.0", "beta", minimum_code=13)
        self.assertEqual(result["version_code"], 14)


if __name__ == "__main__":
    unittest.main()
