import unittest

from record_acceptance_evidence import render_evidence


class AcceptanceEvidenceTests(unittest.TestCase):
    # REGRESSION CONTRACT: RELEASE-001
    def test_local_report_keeps_real_device_gates_pending(self):
        report = render_evidence(
            revision="abc123",
            branch="feature/test",
            worktree="clean",
            local_status="通过",
            device_status="no devices",
            created_at="2026-10-17T00:00:00+00:00",
        )
        self.assertIn("Revision: `abc123`", report)
        self.assertIn("| L3 | 待验收", report)
        self.assertIn("| L4 | 待验收", report)
        self.assertIn("DLNA discovery", report)


if __name__ == "__main__":
    unittest.main()
