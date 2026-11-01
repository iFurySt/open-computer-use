## [2026-11-01 16:45] | Task: Add an opt-in minimal (all-black) Locked Use shield

### 🤖 Execution Context
* **Agent ID**: `hermes (default profile), user-supervised`
* **Base Model**: `claude-sonnet-5-5`
* **Runtime**: `Hermes desktop agent on macOS 26.4.1 arm64, OCU 1.1.2`

### 📥 User Query
> The lock-screen shield is very bright and colourful (blurred wallpaper, avatar, badge, two text lines). Is there a headless / dark option, like a privacy mode in a remote-desktop tool?

### 🛠 Changes Overview
**Scope:** `experiments/LockedUse` (Guardian)

**Key Actions:**
- **ShieldStyle**: new `standard` (default, unchanged) and `minimal` styles, selected with `defaults write com.ifuryst.opencomputeruse LockedUseShieldStyle minimal`.
- **Minimal rendering**: pure black fill, no wallpaper, avatar, badge or text. The shield window, window level, sharing type, input handling and coverage checks are untouched.

### 🧠 Design Intent (Why)
The standard shield shows a dimmed wallpaper plus avatar and text on every display, which is a very bright surface in a dark room. Some users want the screen to look off. The change is cosmetic and opt-in, so the default behaviour and the privacy guarantees do not change.

### 📁 Files Modified
- `experiments/LockedUse/Sources/Guardian/ShieldAppearance.swift`
