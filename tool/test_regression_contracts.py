import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import check_regression_contracts as contracts


class RegressionContractTests(unittest.TestCase):
    def test_registry_has_unique_contracts_and_real_test_markers(self):
        data = json.loads(contracts.REGISTRY.read_text())
        self.assertEqual(contracts.validate_contracts(data), [])

    def test_future_validation_doc_requires_explicit_status(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            docs = root / "docs" / "validation"
            docs.mkdir(parents=True)
            future = docs / "v9.9.9.alpha1-验证.md"
            future.write_text("# Future\n")
            with patch.object(contracts, "ROOT", root):
                self.assertTrue(contracts.validate_future_validation_docs("0.1.0"))
            future.write_text("文档状态：历史验证草稿\n# Future\n")
            with patch.object(contracts, "ROOT", root):
                self.assertEqual(contracts.validate_future_validation_docs("0.1.0"), [])


if __name__ == "__main__":
    unittest.main()
