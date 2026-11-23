# Discover app-owned macOS status items

## Request
Make macOS menu-bar status items discoverable to agents without relying on screen coordinates or global pointer input.

## Changes
- Render the owning app's accessibility extras menu bar as a separate section in the existing indexed app snapshot.
- Explain the status-item workflow in the JavaScript tool's built-in guidance: bind, inspect, use an accessibility-only click, and inspect again.
- Cover discoverability and the documented call sequence in a fresh REPL session with a mocked native transport.

## Validation
The native executable builds on macOS and all 33 REPL tests pass. Live status-item menu opening and action selection still need verification; the mock does not exercise macOS Accessibility.
