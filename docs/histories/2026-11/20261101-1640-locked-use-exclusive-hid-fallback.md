## [2026-11-01 16:40] | Task: Keep Locked Use working when another tool seizes keyboards exclusively

### 🤖 Execution Context
* **Agent ID**: `hermes (default profile), user-supervised`
* **Base Model**: `claude-sonnet-5-5`
* **Runtime**: `Hermes desktop agent on macOS 26.4.1 arm64, OCU 1.1.2`

### 📥 User Query
> Locked Use fails whenever Karabiner-Elements is running. Fix it so both can coexist (see issue #142).

### 🛠 Changes Overview
**Scope:** `experiments/LockedUse` (Guardian)

**Key Actions:**
- **PhysicalInputMonitor fallback**: when the all-or-nothing `IOHIDManagerOpen` returns `kIOReturnExclusiveAccess`, open the matched devices one by one and continue if at least one input source is observable.
- **Cleanup**: devices opened individually are unscheduled and closed in `stop()`.

### 🧠 Design Intent (Why)
Karabiner-Elements seizes the built-in keyboard, Bluetooth keyboards and the TouchBar device and re-emits keys through its DriverKit virtual keyboard. The monitor only needs to know that *some* physical activity can be observed, so a seized device must not abort the whole Locked Use turn. Any other failure still aborts as before.

### 📁 Files Modified
- `experiments/LockedUse/Sources/Guardian/PhysicalInputMonitor.swift`
