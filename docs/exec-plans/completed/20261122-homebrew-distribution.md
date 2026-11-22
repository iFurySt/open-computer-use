# Homebrew distribution for macOS

Issue #192 asks for a Homebrew install that reuses the signed and notarized universal macOS release.

- [x] Publish a dedicated tap and expose both native command names from the app bundle.
- [x] Verify install, upgrade, native MCP, and uninstall with isolated Homebrew state.
- [x] Automate cask updates in the tap from stable GitHub Releases, with manifest and archive checks.
- [x] Document install, migration, and command scope in both READMEs.

The native cask requires macOS 14+ and Homebrew 6.0.13+. Linux Homebrew and packaging the Node wrapper are separate follow-ups. See the [history](../../histories/2026-11/20261122-1100-homebrew-distribution.md) for the launcher choice and validation.
