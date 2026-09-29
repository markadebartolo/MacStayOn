# MacStayOn for Windows

Tray-only Windows app that keeps your laptop **awake when the lid is closed** (battery or plugged in). Same idea as the macOS MacStayOn app.

## What it does

| Toggle | Behavior |
|--------|----------|
| **On** | Sets **When I close the lid → Do nothing** for AC and battery (`powercfg`), and holds a system stay-awake request |
| **Off** / **Quit** | Restores your previous lid-close actions and releases stay-awake |

Shows a heat/enclosure warning before enabling. Toggle desire is saved under `%LOCALAPPDATA%\MacStayOn\state.json`.

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
cd windows\MacStayOn
dotnet build -c Release
dotnet run -c Release
```

Or run the exe:

```powershell
.\bin\Release\net8.0-windows\MacStayOn.exe
```

Look for the tray icon (system tray / notification area). Right-click (or left-click) for the menu.

## Verify

```powershell
# After turning On:
powercfg /query SCHEME_CURRENT SUB_BUTTONS LIDACTION
# AC and DC "Current … Setting Index" should be 0x00000000 (Do nothing)

# After Off or Quit: values should match what you had before
```

## Notes

- You usually do **not** need admin for personal power-plan lid settings. If `powercfg` fails, the menu shows the error and stays Off.
- Closing the lid with MacStayOn **on** should leave the machine awake — keep it ventilated (not in a bag).
- This folder is Windows-only; the macOS app lives at the repo root.
