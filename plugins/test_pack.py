import copy
import json
import tempfile
import unittest
from pathlib import Path

import pack


ROOT = Path(__file__).resolve().parent


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.package = json.loads((ROOT / "template/manifest.json").read_text())
        self.package["script"] = (ROOT / "template/plugin.js").read_text()

    def test_template_and_examples_validate(self):
        for source in (ROOT / "template", ROOT / "agent-status", ROOT / "session-notifications"):
            with self.subTest(source=source.name), tempfile.TemporaryDirectory() as directory:
                output = Path(directory) / "test.wakeguardplugin"
                pack.pack(source, output)
                package, data = pack.read_package(output)
                self.assertEqual(package["script"], (source / "plugin.js").read_text())
                self.assertLessEqual(len(data), pack.PACKAGE_LIMIT)

    def test_rejects_invalid_identity_and_capabilities(self):
        mutations = [
            lambda value: value.update(apiVersion=True),
            lambda value: value.update(id="../../escape"),
            lambda value: value.update(version="1.0.0-beta"),
            lambda value: value.update(homepage="https://user:password@example.com"),
            lambda value: value.update(script="x" * (pack.SCRIPT_LIMIT + 1)),
            lambda value: value["permissions"].update(notifications="false"),
            lambda value: value["permissions"].update(network=["*.example.com"]),
            lambda value: value["permissions"].update(network=["EXAMPLE.COM"]),
            lambda value: value["permissions"].update(network=["example.com:443"]),
            lambda value: value["permissions"].update(network=["example.com", "example.com"]),
            lambda value: value.update(settings=[{
                "key": "token", "label": "Token", "type": "secret",
                "required": True, "defaultValue": "never-package-a-token"
            }]),
            lambda value: value.update(settings=[{
                "key": "enabled", "label": "Enabled", "type": "toggle",
                "required": False, "defaultValue": True
            }]),
            lambda value: value.update(commands=[{"id": "test", "title": "Test"}] * 2),
        ]
        for index, mutate in enumerate(mutations):
            with self.subTest(index=index):
                value = copy.deepcopy(self.package)
                mutate(value)
                with self.assertRaises(ValueError):
                    pack.validate(value)

    def test_catalog_requires_canonical_paths_and_verifies_metadata_and_hash(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            package = root / self.package["id"] / (self.package["version"] + ".wakeguardplugin")
            pack.pack(ROOT / "template", package)
            catalog = root / "catalog.json"
            pack.catalog(catalog, [package])
            self.assertEqual(pack.verify(catalog), 1)
            package.write_bytes(package.read_bytes() + b"\n")
            with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                pack.verify(catalog)
            pack.catalog(catalog, [package])
            index = json.loads(catalog.read_text())
            index["plugins"][0]["name"] = "Different name"
            catalog.write_text(json.dumps(index))
            with self.assertRaisesRegex(ValueError, "name mismatch"):
                pack.verify(catalog)
            with self.assertRaisesRegex(ValueError, "Place package"):
                pack.catalog(root / "wrong/catalog.json", [package])

    def test_rejects_nonstandard_json_constants_even_in_unknown_fields(self):
        for constant in ("NaN", "Infinity", "-Infinity"):
            with self.subTest(constant=constant), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                package = root / "invalid.wakeguardplugin"
                package.write_text(json.dumps(self.package)[:-1] + ', "unused": ' + constant + '}')
                with self.assertRaisesRegex(ValueError, "Invalid JSON constant"):
                    pack.read_package(package)
                manifest = dict(self.package)
                manifest.pop("script")
                (root / "manifest.json").write_text(json.dumps(manifest)[:-1] + ', "unused": ' + constant + '}')
                (root / "plugin.js").write_text(self.package["script"])
                with self.assertRaisesRegex(ValueError, "Invalid JSON constant"):
                    pack.pack(root, root / "output.wakeguardplugin")
                catalog = root / "catalog.json"
                catalog.write_text('{"schemaVersion": 1, "plugins": [], "unused": ' + constant + '}')
                with self.assertRaisesRegex(ValueError, "Invalid JSON constant"):
                    pack.verify(catalog)
        self.package["unused"] = {"validJSON": True}
        pack.validate(pack.decode_json(json.dumps(self.package)))

    def test_shipped_catalog_matches_sources(self):
        catalog = ROOT.parent / "public/plugins/catalog.json"
        self.assertEqual(pack.verify(catalog), 2)
        for name in ("agent-status", "session-notifications"):
            source = ROOT / name
            manifest = json.loads((source / "manifest.json").read_text())
            shipped = catalog.parent / manifest["id"] / (manifest["version"] + ".wakeguardplugin")
            with tempfile.TemporaryDirectory() as directory:
                rebuilt = Path(directory) / shipped.name
                pack.pack(source, rebuilt)
                self.assertEqual(rebuilt.read_bytes(), shipped.read_bytes())


if __name__ == "__main__":
    unittest.main()
