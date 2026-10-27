import unittest

import check_ui_tokens

# REGRESSION CONTRACT: UI-GLASS-001


class UiTokenContractTests(unittest.TestCase):
    def test_runtime_and_snapshot_are_aligned(self):
        self.assertEqual(check_ui_tokens.validate(), [])


if __name__ == "__main__":
    unittest.main()
