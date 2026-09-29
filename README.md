# MacStayOn

Keep a laptop **awake when the lid is closed** so agents and other work keep running.

| Platform | Location |
|----------|----------|
| **macOS** (menu bar) | this repo root — see below |
| **Windows** (system tray) | [`windows/PCStayOn`](windows/PCStayOn/) |

---

## macOS

Menu-bar-only macOS app that keeps your MacBook **fully awake when the lid is closed** (including on battery). Toggle it off and normal lid-sleep behavior returns.

## What it does

| Toggle | Behavior |
|--------|----------|
| **On** (sun icon) | Runs `pmset -a disablesleep 1` (admin password once) **and** holds an IOKit `PreventSystemSleep` assertion so closing the lid does **not** sleep — on AC or battery |
| **Off** (moon icon) | Restores the previous `disablesleep` value and releases the assertion |

State is saved in `UserDefaults` and re-applied on relaunch (re-applying On shows the admin dialog again).

`PreventSystemSleep` alone is **not** enough on battery: macOS still sleeps on lid-close. `pmset disablesleep` is what actually blocks that without an external display.

## Requirements

- macOS 13 Ventura or later
- Xcode (for `xcodebuild`) and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- **Admin password** when turning On (standard macOS authorization dialog)

## Permissions

- **Admin authorization** when enabling (to change `pmset`). Canceling leaves the toggle Off and the menu says so.
- No Accessibility or Full Disk Access required.
- First launch of an unsigned local build: right-click → **Open**, or allow under **System Settings → Privacy & Security**.
- Sandbox is **off** (required for IOKit + invoking privileged `pmset`).

## Build & run

```bash
chmod +x scripts/build.sh
./scripts/build.sh
open dist/MacStayOn.app
```

Or in Xcode:

```bash
xcodegen generate
open MacStayOn.xcodeproj
```

Then Run (⌘R). No Dock icon (`LSUIElement`) — look for the **sun** / **moon** icon in the menu bar.

### Menu

1. Status line — current mode  
2. Detail — `disablesleep`, assertion, AC/battery  
3. **Turn On / Turn Off** — On shows a heat/enclosure warning first (Cancel stays Off; Continue goes to the admin password dialog)  
4. **Quit MacStayOn** (restores prior sleep settings)

### Quick verify

```bash
# After enabling (and approving admin):
pmset -g | grep disablesleep          # expect: disablesleep 1
pmset -g assertions | grep -i MacStayOn # PreventSystemSleep assertion

# After Off or Quit:
pmset -g | grep disablesleep          # expect absent or 0
```

## Notes

- Turning On starts a privileged watchdog that restores the previous `disablesleep` when you turn Off, quit, or the app process exits — so sleep is not left disabled after a clean exit.
- Closing the lid with MacStayOn **on** should leave the machine awake on battery or AC (no external display required).
- Menu bar only — no settings windows.
