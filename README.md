# LidAwake

Menu-bar-only macOS app that keeps your MacBook **fully awake when the lid is closed**, so Claude/agents and other work can keep running. Toggle it off and normal lid-sleep behavior returns.

## What it does

| Toggle | Behavior |
|--------|----------|
| **On** (sun icon) | Holds an IOKit `PreventSystemSleep` power assertion so closing the lid does **not** put the machine to sleep |
| **Off** (moon icon) | Releases the assertion — normal closed-lid sleep |

State is saved in `UserDefaults` and restored on relaunch.

This is **not** idle-only `caffeinate`. It uses the same class of system sleep assertion that apps like KeepingYouAwake / Amphetamine use for closed-clamshell stay-awake.

## Requirements

- macOS 13 Ventura or later
- Xcode (for `xcodebuild`) and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- **AC power recommended.** Apple generally honors `PreventSystemSleep` on adapter power. On battery, macOS may still sleep on lid close for thermal/safety policy — the menu shows when you’re on battery.

## Permissions

No Accessibility, Full Disk Access, or other TCC prompts are required for the power assertion path.

- First launch of an unsigned local build: right-click the app → **Open**, or allow it under **System Settings → Privacy & Security** if Gatekeeper blocks it.
- Sandbox is **off** (required for IOKit power assertions in this setup).

## Build & run

```bash
chmod +x scripts/build.sh
./scripts/build.sh
open dist/LidAwake.app
```

Or in Xcode:

```bash
xcodegen generate
open LidAwake.xcodeproj
```

Then Run (⌘R). The app has no Dock icon (`LSUIElement`) — look for the **sun** / **moon** icon in the menu bar.

### Menu

1. Status line — current mode  
2. **Turn On / Turn Off** — toggle stay-awake  
3. **Quit LidAwake**

### Quick verify

```bash
# After enabling in the menu:
pmset -g assertions | grep -i LidAwake
```

You should see a `PreventSystemSleep` assertion owned by LidAwake.

## Notes

- Quitting the app releases the assertion (normal lid sleep resumes).
- Closing the lid with Stay Awake **on** and the Mac on AC should leave the machine awake (fans/CPU continue; agents keep running).
- This does not create a window or settings UI — menu bar only by design.
