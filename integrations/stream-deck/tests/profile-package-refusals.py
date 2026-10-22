"""Exercise package metadata refusals without importing/extracting anything."""
import importlib.util
from pathlib import Path
import stat
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("profile_package", ROOT / "scripts/check-profile-package.py")
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


class PackageEntries(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="stream-owned-profile-package-")
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / "owned.streamDeckPlugin"

    def write(self, extra=None):
        # Minimal owned fixture with the same exact candidate/manifest/license
        # contracts. No built helper or real application installation is needed.
        prefix = checker.PLUGIN + "/"
        files = {"manifest.json": (ROOT / checker.PLUGIN / "manifest.json").read_bytes(),
                 "THIRD_PARTY_LICENSES.txt": (ROOT / "profiles/ELGATO_MEMORYGAME_LICENSE.txt").read_bytes()}
        files.update({"profiles/" + path.name: path.read_bytes()
                      for path in (ROOT / checker.PLUGIN / "profiles").glob("*.streamDeckProfile")})
        with zipfile.ZipFile(self.path, "w") as package:
            for name, contents in files.items():
                entry = zipfile.ZipInfo(prefix + name)
                entry.create_system = 3
                entry.external_attr = (stat.S_IFREG | 0o644) << 16
                package.writestr(entry, contents)
            if extra:
                name, kind = extra
                entry = zipfile.ZipInfo(name)
                entry.create_system = 3
                entry.external_attr = (kind | 0o755) << 16
                package.writestr(entry, b"" if name.endswith("/") else b"owned fixture")

    def test_regular_files_and_directory_are_accepted(self):
        self.write((checker.PLUGIN + "/owned-empty/", stat.S_IFDIR))
        checker.check_package(self.path)

    def test_links_and_nonregular_types_are_rejected(self):
        for kind in (stat.S_IFLNK, stat.S_IFIFO, stat.S_IFSOCK, stat.S_IFCHR, stat.S_IFBLK):
            with self.subTest(kind=kind):
                self.write((checker.PLUGIN + "/owned-entry", kind))
                with self.assertRaisesRegex(AssertionError, "Unsupported package entry type"):
                    checker.check_package(self.path)

    def test_backslash_paths_are_rejected(self):
        self.write((checker.PLUGIN + "/owned\\entry", stat.S_IFREG))
        with self.assertRaisesRegex(AssertionError, "Backslash package path"):
            checker.check_package(self.path)

    def test_type_and_directory_suffix_must_agree(self):
        for name, kind in (("directory", stat.S_IFDIR), ("file/", stat.S_IFREG)):
            with self.subTest(name=name):
                self.write((checker.PLUGIN + "/" + name, kind))
                with self.assertRaisesRegex(AssertionError, "Package entry type/path mismatch"):
                    checker.check_package(self.path)


if __name__ == "__main__":
    unittest.main(verbosity=2)
