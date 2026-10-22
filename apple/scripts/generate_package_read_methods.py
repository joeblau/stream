"""Copy shipping package transactions into an inert, package-only test shell.

Every copied slice and generated file is hashed before compilation. This is not
a StudioRuntime substitute: runtime/output behavior is explicitly untested.
"""
import argparse
import hashlib
import json
from pathlib import Path

APPLE = Path(__file__).resolve().parents[1]


def sha(text):
    return hashlib.sha256(text.encode()).hexdigest()


def generate(folder):
    folder.mkdir(parents=True, exist_ok=True)
    records = []

    def slice_file(name, start, end=None):
        source = (APPLE / name).read_text()
        if source.count(start) != 1 or (end and source.count(end) != 1):
            raise ValueError(f"Source boundary changed: {name}: {start}")
        first = source.index(start)
        last = source.index(end, first) if end else len(source)
        value = source[first:last]
        records.append(dict(source=name, firstLine=source[:first].count("\n") + 1,
                            start=start, end=end, sha256=sha(value)))
        return value

    ws = "StreamMac/StudioWorkspace.swift"
    properties = []
    for line in ["    @Published private(set) var catalog: StudioProjectCatalog\n",
                 "    @Published var pending: Selection?\n",
                 "    @Published var error: String?\n",
                 "    @Published var showProjects = false\n",
                 "    @Published var recoveryFile: URL?\n"]:
        source = (APPLE / ws).read_text()
        if source.count(line) != 1:
            raise ValueError("Workspace property changed: " + line)
        records.append(dict(source=ws, start=line.rstrip(), end="single line", sha256=sha(line)))
        properties.append(line)
    properties.append(slice_file(ws, "    @Published var importPreview:",
                                  "    @Published var showRecordingLibrary"))
    fields = slice_file(ws, "    struct Selection: Equatable {", "    var selection: Selection")
    methods = []
    for start, end in [
        ("    func directory(for selection:", "    func stage(project:"),
        ("    private func saveCatalog()", "    func acceptRecoveredCatalog()"),
        ("    func previewPackage(_ url:", "    func importPreviewedPackage()"),
        ("    func importPreviewedPackage()", "    func exportPackage("),
        ("    private func beginPackageWrite()", "    /// Capture retained security grants")]:
        methods.append(slice_file(ws, start, end))
    preview = "ShowPackageIO.preview(url)"
    bound = "ShowPackageIO.importFiles(from: preview.url, to: destination, previewedManifest: preview.manifest)"
    body = "".join(methods)
    if body.count(preview) != 1 or body.count(bound) != 1:
        raise ValueError("Actual manifest-bound IO boundary changed")
    body = body.replace(preview, "PackageReadProbe.preview(url)").replace(bound, bound.replace("ShowPackageIO", "PackageReadProbe"))
    task = "        Task { [weak self] in\n"
    if body.count(task) != 1:
        raise ValueError("Preview completion boundary changed")
    body = body.replace(task, task + "            defer { PackageReadProbe.previewReturned(url) }\n")
    export = slice_file(ws, "    func exportPackage(includeMedia:", "        let panel = NSSavePanel()")
    export += '        preconditionFailure("Package-only fixture reached native export panel boundary")\n    }\n'
    init = """
    // Fixture-only root/catalog initialization. No StudioRuntime exists here.
    init() {
        root = GuestFixtureStorage.machineDirectory
        catalogURL = root.appendingPathComponent("projects.v1.json")
        catalog = try! JSONDecoder().decode(StudioProjectCatalog.self, from: Data(contentsOf: catalogURL))
    }
"""
    workspace = "import AppKit\nimport Combine\nimport Foundation\nimport StreamCore\n\n@MainActor final class StudioWorkspace: ObservableObject {\n" + "".join(properties) + fields + init + body + export + "}\n"
    dependencies = "import Foundation\nimport Security\nimport StreamCore\n\n"
    dependencies += slice_file("StreamMac/AssetLibraryStore.swift", "final class ResolvedAssetAccess:")
    dependencies += slice_file("StreamMac/StudioControlPairingStore.swift", "@MainActor protocol StudioControlCredentials", "@MainActor private struct StudioControlKeychainCredentials")
    dependencies += slice_file("StreamMac/TransitionController.swift", "enum SceneTransitionStyle:", "// MARK: - Take → program-engine hand-off")
    dependencies += slice_file("StreamMac/WebOverlayIntegration.swift", "extension LayerPayload {", "private final class BrowserWidgetIdentity:")
    dependencies += slice_file("StreamMac/MediaSourcePlayback.swift", "enum MediaSourceFactory {", "/// Serializes only sample delivery.")
    dependencies += """
enum GuestFixtureStorage {
    static var machineDirectory: URL {
        precondition(CommandLine.arguments.count == 2, "Owned fixture directory required")
        return URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    }
}
"""
    harness = (APPLE / "scripts/package_read_harness.swift").read_text()
    guard = '''        try require(!workspace.runtime.controller.outputSessionActive && !workspace.runtime.recorder.state.isActive,
            "Package fixture allocated an output")'''
    if harness.count(guard) != 1:
        raise ValueError("Full-graph output guard changed")
    harness = harness.replace(guard, '        print("SCOPE: StudioRuntime/controller/recorder not constructed; their behavior not tested")')
    generated = {"WorkspacePackageMethods.swift": workspace,
                 "PackageDependencies.swift": dependencies,
                 "PackageReadHarness.swift": harness}
    for name, source in generated.items():
        (folder / name).write_text(source)
    receipt = dict(scope="Package IO and copied Workspace transactions only; no StudioRuntime/controller/recorder, UI, permissions, devices, preferences or network",
                   slices=records, generated={name: sha(value) for name, value in generated.items()},
                   harnessOmission="Only final full-runtime output predicate; original normal harness retains it",
                   ioProbes="Actual IO, required previewedManifest forwarded unchanged; original NSCondition holds")
    (folder / "generation.json").write_text(json.dumps(receipt, indent=2) + "\n")
    return receipt


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("folder", type=Path)
    args = parser.parse_args()
    print(json.dumps(generate(args.folder), indent=2))
