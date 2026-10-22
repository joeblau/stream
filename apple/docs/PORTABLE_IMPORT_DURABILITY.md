# Portable import durability

An imported show is now published to the workspace and staged only after its candidate catalog has been persisted and the exact saved bytes have been read back. Unaccepted catalog recovery refuses import before copying. A failed precommit save removes only the newly owned imported profile; a history-pruning error after a verified catalog commit keeps the show and reports a saved-show warning.

The importer rechecks the current durable catalog after detached copying, preserving legitimate intervening edits. Cancel revokes the captured preview/task's commit and error authority while capacity remains occupied until actual IO finishes. An ambiguous attempted save retains the copied files and blocks normal catalog edits, saves and imports until reload. Startup distinguishes confirmed absence from unreadable, invalid or dangling existing catalog paths, preserving originals and requiring deliberate recovery.

The [machine receipt](PORTABLE_IMPORT_DURABILITY_2026-10-22.json) binds 22 source files and 32 retained artifacts. Two actual native fixtures passed with a copied StreamCore framework, `swiftc -j2`, the shared two-slot wrapper and unchanged 45-second child bounds. The transaction cases exercise real history-blocker and immutable-backup pruning failures, actual concurrent archive/save, sheet-only cancellation followed by a real import error, and actual unreadable-file restart handling. Only the final post-write readback is replaced for the two unavailable/unexpected readback controls. The five-phase actual package IO fixture retains its manifest and capacity assertions; its corrected cancellation contract is followed by a fresh explicit retry that still verifies source-A scene content. Four generation tests passed.

An exact original import-method control failed the recovery-refusal assertion as expected. This control uses the original method in the new inert fixture shell with the same held real IO boundary; it is not an untouched full-app run. The initial fixture setup failure and invalid control splice compile failure remain retained separately.

These tests instantiate no StudioRuntime, controller or recorder and do not qualify Finder, LaunchServices, a native keyboard chooser, sandbox entitlements or full-window interaction. They leave the original #155 interaction qualification open.

To reproduce using already-built matching StreamCore products:

```sh
PACKAGE_METHODS_CORE_PRODUCTS=/owned/immutable-products \
  zsh apple/scripts/run_package_import_transaction_harness.zsh
PACKAGE_METHODS_CORE_PRODUCTS=/owned/immutable-products \
  zsh apple/scripts/run_package_read_methods_harness.zsh
python3 -B -m unittest discover -s apple/scripts -p test_package_read_generation.py
```
