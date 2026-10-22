"""Exercise the actual Ruby Workspace replacement without building or runtime IO."""
from pathlib import Path
import subprocess
import unittest
from tempfile import TemporaryDirectory

from generate_package_read_methods import generate


APPLE = Path(__file__).resolve().parents[1]


class PackageReadGenerationTests(unittest.TestCase):
    def generate(self, workspace):
        runner = (APPLE / "scripts/run_package_read_harness.zsh").read_text()
        begin = "replace_source(target, root, folder, 'StudioWorkspace.swift') do |source|"
        end = "replace_source(target, root, folder, 'ProviderAccountSession.swift')"
        self.assertEqual(runner.count(begin), 1)
        replacement = runner[runner.index(begin):runner.index(end)]
        # Run that exact production-source replacement, with only its filesystem
        # writer replaced. Input/output remain pipes; no fixture/project is built.
        program = """
target = {}; root = ''; folder = ''
def replace_source(*args)
  print yield(STDIN.read)
end
""" + replacement
        return subprocess.run(["ruby", "-e", program], input=workspace,
                              capture_output=True, text=True, timeout=10)

    def test_current_manifest_bound_import_generates_and_retains_binding(self):
        workspace = (APPLE / "StreamMac/StudioWorkspace.swift").read_text()
        result = self.generate(workspace)
        self.assertEqual(result.returncode, 0, result.stderr)
        expected = ("PackageReadProbe.importFiles(from: preview.url, to: destination, "
                    "previewedManifest: preview.manifest)")
        self.assertIn(expected, result.stdout)
        self.assertNotIn("PackageReadProbe.importFiles(from: preview.url, to: destination)", result.stdout)
        self.assertIn("defer { PackageReadProbe.previewReturned(url) }", result.stdout)

    def test_unbound_import_source_is_refused_before_fixture_generation(self):
        workspace = (APPLE / "StreamMac/StudioWorkspace.swift").read_text()
        bound = "ShowPackageIO.importFiles(from: preview.url, to: destination, previewedManifest: preview.manifest)"
        self.assertEqual(workspace.count(bound), 1)
        result = self.generate(workspace.replace(bound, "ShowPackageIO.importFiles(from: preview.url, to: destination)"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Actual import IO boundary changed", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_inert_copy_preserves_all_package_assertions_and_only_omits_runtime_guard(self):
        with TemporaryDirectory() as directory:
            folder = Path(directory)
            receipt = generate(folder)
            original = (APPLE / "scripts/package_read_harness.swift").read_text()
            guard = '''        try require(!workspace.runtime.controller.outputSessionActive && !workspace.runtime.recorder.state.isActive,
            "Package fixture allocated an output")'''
            expected = original.replace(guard, '        print("SCOPE: StudioRuntime/controller/recorder not constructed; their behavior not tested")')
            self.assertEqual((folder / "PackageReadHarness.swift").read_text(), expected)
            workspace = (folder / "WorkspacePackageMethods.swift").read_text()
            for forbidden in ("StudioRuntime()", "NSSavePanel()", "UserDefaults", "PermissionsManager", "StreamController"):
                self.assertNotIn(forbidden, workspace)
            self.assertIn("guard let operation = beginPackageWrite() else { return }", workspace)
            self.assertIn("preconditionFailure", workspace)
            self.assertIn("previewedManifest: preview.manifest", workspace)
            self.assertEqual(len(receipt["slices"]), 18)


if __name__ == "__main__":
    unittest.main(verbosity=2)
