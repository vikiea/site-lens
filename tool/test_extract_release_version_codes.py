import unittest

from extract_release_version_codes import extract


class ExtractReleaseVersionCodesTest(unittest.TestCase):
    def test_reads_only_explicit_version_code_lines(self):
        self.assertEqual(
            extract(
                [
                    {"tag_name": "v0.2.0.alpha2", "body": "- 版本：`0.2.0.alpha2`，versionCode `13`"},
                    {"tag_name": "v0.2.0.beta1", "body": "- Android versionCode: `14`."},
                    {"tag_name": "v0.2.0.alpha1", "body": "source-only"},
                    {"tag_name": "v0.2.0.draft", "draft": True, "body": "- Android versionCode: `99`."},
                    {"tag_name": "v0.2.0.fake", "body": "versionCode: `88`"},
                ]
            ),
            {"v0.2.0.alpha2": 13, "v0.2.0.beta1": 14},
        )

if __name__ == "__main__":
    unittest.main()
