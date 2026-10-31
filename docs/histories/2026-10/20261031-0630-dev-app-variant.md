# Release-optimized builds that keep the development app identity

Date: 2026-10-31

Request (condensed): measure release-optimized code in the development app, whose
Accessibility and Screen Recording grants already exist, without replacing or
deleting an installed release app.

- `scripts/build-open-computer-use-app.sh` accepts `OPEN_COMPUTER_USE_APP_VARIANT=dev`.
  With `release` it builds optimized binaries but keeps
  `com.ifuryst.opencomputeruse.dev`, the `(Dev)` name and `OpenComputerUseAppVariant=dev`.
  Any other value fails before building.
- An explicit dev build removes only its own bundle; neighboring release and legacy
  bundles in the output directory stay.
- Automatic Locked Use packaging stays limited to the release identity. Explicit
  `OPEN_COMPUTER_USE_INCLUDE_LOCKED_USE=1` with a dev release build is refused, because
  the components follow the build configuration and would not match the dev bundle.
- Unset, the script behaves as before.
- Documented the option in `docs/ARCHITECTURE.md`. No release note: this is a
  developer build option.

Validation: `bash -n` passed. An unknown variant and the Locked Use combination exit 1
before building. Unsigned (`OPEN_COMPUTER_USE_CODESIGN_MODE=none`) dev release builds
into an isolated output directory produced `Open Computer Use (Dev).app` with
`com.ifuryst.opencomputeruse.dev`, variant `dev` and no Locked Use resources, and kept
a neighboring `Open Computer Use.app`. Signed builds were not exercised.
`make check-docs` passed.

## Maintainer review on current main

- Merged current main and checked callers of the build script. A dev override inherited by packaging could build Dev while leaving a stale release bundle selected. Release/npm packaging and plugin installation now reject the override before build, cleanup or copying; this variable is for direct app builds only.
- Added `scripts/tests/app-variant.test.mjs`: invalid variants, mismatched Locked Use, packaging with/without rebuild, and plugin installation fail before modifying existing output. Two tests pass, and the distribution workflow runs them.
- Added `scripts/tests/macos-app-variant-smoke.py`. Actual native release/dev build was Developer ID signed and passed deep/strict verification; bundle identifier and variant are dev, no Locked Use resources are embedded in auto mode, and neighboring release/legacy sentinels survive. Actual default debug and release builds retain their existing identities. All three combinations pass in temporary output directories.
- Existing release packaging tests: 2 passed. Shell syntax, documentation and diff checks pass. No Swift runtime changes or installed app/permission changes.
- The source organization fork rejected maintainer writes during this batch, so reviewed changes are delivered from a maintainer branch with the original commits and explicit co-author credit.
