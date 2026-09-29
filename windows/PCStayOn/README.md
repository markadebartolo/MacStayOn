# PCStayOn for Windows

Tray-only Windows app that keeps your laptop **awake when the lid is closed** (battery or plugged in). Same idea as the macOS **MacStayOn** app.

## What it does

| Toggle | Behavior |
|--------|----------|
| **On** | Sets **When I close the lid → Do nothing** for AC and battery (`powercfg`), and holds a system stay-awake request |
| **Off** / **Quit** | Restores your previous lid-close actions and releases stay-awake |

Shows a heat/enclosure warning before enabling. Toggle desire is saved under `%LOCALAPPDATA%\PCStayOn\state.json`.

## Requirements

- Windows 10/11
- [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0)

### Install .NET 8 SDK (PowerShell)

```powershell
winget install Microsoft.DotNet.SDK.8
```

Or download from the link above. Then open a **new** terminal and confirm:

```powershell
dotnet --version
```

## Build & run

```powershell
cd windows\PCStayOn
dotnet build -c Release
dotnet run -c Release
```

Or run the exe:

```powershell
.\bin\Release\net8.0-windows\PCStayOn.exe
```

Look for the tray icon (system tray / notification area). Right-click (or left-click) for the menu.

## Verify

```powershell
# After turning On in the tray:
powercfg /query SCHEME_CURRENT SUB_BUTTONS LIDACTION
# AC and DC indexes should be 0x00000000 (Do nothing)

powercfg /requests
# Should list PCStayOn / SYSTEM under SYSTEM or AWAYMODE
```

**Important:** when you close the lid, the built-in screen goes dark. That is normal.
Success = the PC keeps running. Easy check: start `ping -t 8.8.8.8` in a window, close the lid for 30s, open it — ping should have continued without a long pause.

If lid action won't stick, run PowerShell **as Administrator** and try again.

## Notes

- You usually do **not** need admin for personal power-plan lid settings. If `powercfg` fails, the menu shows the error and stays Off.
- Closing the lid with PCStayOn **on** should leave the machine awake — keep it ventilated (not in a bag).
- This folder is Windows-only; the macOS app lives at the repo root.
