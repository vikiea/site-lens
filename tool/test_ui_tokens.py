import tempfile
import unittest
from pathlib import Path

import check_ui_tokens as contract

# REGRESSION CONTRACT: UI-GLASS-001


class UiTokenContractTests(unittest.TestCase):
    def test_repository_contract_holds(self):
        self.assertEqual(contract.validate(), [])

    def _fixture(self, root: Path) -> None:
        (root / "lib/ui").mkdir(parents=True)
        (root / "lib/settings").mkdir(parents=True)
        runtime = "\n".join(runtime for runtime, _ in contract.REQUIRED.values())
        (root / "lib/ui/app_theme.dart").write_text(runtime)
        (root / "lib/settings/app_settings.dart").write_text(
            contract.DEFAULT_OPACITY[0]
        )

        ui_skill = root / contract.SKILLS / contract.UI_SKILL
        (ui_skill / "references").mkdir(parents=True)
        snapshot = "\n".join(
            snapshot for _, snapshot in contract.REQUIRED.values()
        ) + "\n" + "\n".join(contract.SNAPSHOT_PHRASES)
        (ui_skill / "references/tokens.md").write_text(
            f"# Tokens\n\nRead this when checking tokens.\n\n{snapshot}\n"
        )
        (ui_skill / "SKILL.md").write_text(
            "# Router\n\nRead [tokens](references/tokens.md).\n"
        )

        validation = root / contract.SKILLS / "site-lens-validation"
        (validation / "references").mkdir(parents=True)
        (validation / "references/validation-matrix.md").write_text(
            "# Matrix\n\nRead this when classifying.\n"
        )
        (validation / "SKILL.md").write_text(
            "# Router\n\nRead [matrix](references/validation-matrix.md).\n"
        )

    def _validate_fixture(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        self._fixture(root)
        return root

    def test_unlinked_reference_is_rejected(self):
        root = self._validate_fixture()
        extra = root / contract.SKILLS / contract.UI_SKILL / "references/extra.md"
        extra.write_text("# Extra\n\nRead this when working on extra.\n")
        errors = contract.validate(root)
        self.assertTrue(
            any("reference not linked from SKILL.md" in error for error in errors),
            errors,
        )

    def test_dangling_router_link_is_rejected(self):
        root = self._validate_fixture()
        router = root / contract.SKILLS / contract.UI_SKILL / "SKILL.md"
        router.write_text(router.read_text() + "\n[missing](references/missing.md)\n")
        errors = contract.validate(root)
        self.assertTrue(
            any("links missing reference" in error for error in errors), errors
        )

    def test_reference_must_state_when_to_read_it(self):
        root = self._validate_fixture()
        extra = root / contract.SKILLS / contract.UI_SKILL / "references/extra.md"
        extra.write_text("# Extra\n\nNo routing line here.\n")
        router = root / contract.SKILLS / contract.UI_SKILL / "SKILL.md"
        router.write_text(router.read_text() + "\n[extra](references/extra.md)\n")
        errors = contract.validate(root)
        self.assertTrue(
            any("must state when to read it" in error for error in errors), errors
        )

    def test_router_must_not_restate_token_values(self):
        root = self._validate_fixture()
        token = next(iter(contract.REQUIRED.values()))[1]
        router = root / contract.SKILLS / contract.UI_SKILL / "SKILL.md"
        router.write_text(f"# Router\n\n[tokens](references/tokens.md) value {token}\n")
        errors = contract.validate(root)
        self.assertTrue(
            any("restated outside the snapshot" in error for error in errors), errors
        )

    def test_runtime_drift_is_rejected(self):
        root = self._validate_fixture()
        (root / "lib/ui/app_theme.dart").write_text("// no tokens")
        errors = contract.validate(root)
        self.assertTrue(
            any("runtime token missing" in error for error in errors), errors
        )


def tokens_line(token: str) -> str:
    return f"[tokens](references/tokens.md) value {token}"


if __name__ == "__main__":
    unittest.main()
