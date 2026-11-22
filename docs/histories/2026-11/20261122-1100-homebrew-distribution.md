# macOS Homebrew cask

Issue #192 asks for a Homebrew installation path for Open Computer Use. The public
[Open Computer Use tap](https://github.com/iFurySt/homebrew-open-computer-use)
installs the signed, notarized universal App from GitHub Releases, starting at
v1.1.5. It exposes the native CLI and MCP server as `ocu` and
`open-computer-use` using Homebrew command wrappers (Homebrew 6.0.13+).

Direct binary symlinks allowed Bundle discovery to pick an older npm App in a
real installation test. The Homebrew wrappers execute the installed App at its
bundle path. The npm distribution still supplies the Node wrapper commands.
The English and Chinese READMEs document migration conflicts, permissions, and
upgrades. Linux Homebrew distribution remains a separate follow-up.

The tap refreshes from the latest stable published release on a schedule using
its own workflow permissions. It checks the release manifest and the downloaded
archive and rejects downgrades or same-version checksum changes. This avoids
adding credentials to the main repository's release workflow.

Verified in an isolated Homebrew prefix on Apple Silicon: install from the public
tap, both CLI version and actual MCP 1.1.5 handshakes with an older npm copy still
present, ignored notifications, ping, strict signature, notarization ticket and
uninstall. Also tested a 1.1.4 → 1.1.5 upgrade from the original symlink layout to
App-path launchers. Real permission grants after migration were not changed or
tested.
