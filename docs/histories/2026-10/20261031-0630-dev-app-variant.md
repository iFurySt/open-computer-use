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
