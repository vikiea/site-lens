#!/usr/bin/env python3
import unittest

from generate_release_notes import Commit, classify, previous_tag, render_notes, tag_channel


class ReleaseNotesTest(unittest.TestCase):
    def test_channel_and_previous_tag_selection(self):
        self.assertEqual(tag_channel("v1.2.3"), "stable")
        self.assertEqual(tag_channel("v1.2.3.beta2"), "beta")
        self.assertEqual(
            previous_tag(["v1.0.0", "v1.1.0", "v1.1.0.beta1"], "v1.1.0.beta2", "beta"),
            "v1.1.0.beta1",
        )
        self.assertEqual(
            previous_tag(
                ["v1.1.0.beta2", "v1.1.0.beta10", "v1.1.0.beta11"],
                "v1.1.0.beta12",
                "beta",
            ),
            "v1.1.0.beta11",
        )
        self.assertIsNone(tag_channel("v1.2.3-beta1"))
        self.assertIsNone(tag_channel("v1.2.3.alpha"))
        self.assertIsNone(tag_channel("v1.2.3.alpha01"))
        self.assertIsNone(tag_channel("v01.2.3"))

    def test_categories_and_human_readable_fallback(self):
        commits = [
            Commit("123456789", "feat(update): add beta channel", ("lib/update/update_service.dart",)),
            Commit("abcdef012", "fix(update): isolate release cache", ("lib/update/update_service.dart",)),
            Commit("fedcba987", "test(update): cover channel selection", ("test/update_channel_test.dart",)),
        ]
        self.assertEqual([classify(commit) for commit in commits], ["功能", "修复", "验证与已知限制"])
        notes = render_notes(
            tag="v1.2.3.alpha1",
            channel="beta",
            base=None,
            commits=commits,
            fallback=True,
        )
        self.assertIn("## 功能", notes)
        self.assertIn("## 修复", notes)
        self.assertIn("## 验证与已知限制", notes)
        self.assertIn("未找到同渠道的上一个发布标签", notes)
        self.assertNotIn("--format=%s", notes)


if __name__ == "__main__":
    unittest.main()
