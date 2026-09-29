<p align="center">
  <img src="docs/media/macstayon-appicon-1024.png" alt="MacStayOn" width="96" height="96">
</p>

<p align="center">
  <strong>MacStayOn</strong><br>
  <sub>Menu bar control for closed-lid stay awake — built for long agent runs</sub>
</p>

<p align="center">
  <a href="https://github.com/markadebartolo/MacStayOn/releases/latest"><strong>Download for macOS</strong></a>
  &nbsp;·&nbsp;
  <a href="https://github.com/markadebartolo/MacStayOn/releases">All releases</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-13%2B-000000?style=flat-square&logo=apple&logoColor=white" alt="macOS 13+">
  <img src="https://img.shields.io/badge/menu%20bar-only-F18636?style=flat-square" alt="Menu bar only">
  <img src="https://img.shields.io/badge/notarized-Developer%20ID-007AFF?style=flat-square&logo=apple&logoColor=white" alt="Notarized">
</p>

<p align="center">
  <img src="docs/media/macstayon-menu.png" alt="MacStayOn menu bar panel — Keep awake with lid closed, heat &amp; battery guard, session timeline" width="360">
</p>

---

## Why MacStayOn

Close the lid and keep working — **Cursor, Claude, builds, and other agents** can keep running without an external display. MacStayOn lives in the **menu bar** (no Dock icon). One tap turns stay-awake on; turn it off and **normal lid sleep** comes back.

> **Safety first:** A closed Mac can overheat in a bag or under a blanket. MacStayOn warns you before enabling and can **turn itself off** on low battery or serious heat.

---

## Get started (macOS)

1. Download **[MacStayOn-macos-arm64.zip](https://github.com/markadebartolo/MacStayOn/releases/latest)** from Releases.
2. Unzip and open **MacStayOn.app** (notarized builds open normally; no right-click workaround needed).
3. Click the **moon** icon in the menu bar.
4. Tap **Keep awake with lid closed** → confirm the heat warning → enter your **admin password** once (required to block lid sleep on battery).
5. Close the lid when you are ready. Open it again and MacStayOn asks whether to **restore normal sleep** or stay on.

**Requirements:** macOS 13 Ventura or later · Apple Silicon or Intel Mac

---

## The menu panel

The popover matches what you see in the app — status first, then one primary action, then guards and session info.

| Section | What it does |
|--------|----------------|
| **Header** | MacStayOn name and **ON** / **OFF** pill |
| **Status** | *Lid closed: normal sleep* or *Lid closed: stays awake* · AC or battery % |
| **Primary button** | **Keep awake with lid closed** (orange) or **Restore normal sleep** when on |
| **Heat & battery guard** | Toggle + *Restore normal sleep at* **10–50%** battery. Also turns off if macOS reports **serious heat**. Only while MacStayOn is on. |
| **Lid-close flash** | While On, closing the lid past ~85° pulses the screen orange until the lid is fully shut (or reopened past that angle). |
| **This session** | Time awake (always visible). Expand to see apps that were working, timeline, and **Clear last session**. Collapsed by default. |
| **Quit** | Restores sleep settings and exits |

Session data stays **on your Mac** — nothing is sent to a server.

---

## What happens under the hood

| When you turn **On** | When you turn **Off** or **Quit** |
|----------------------|-----------------------------------|
| `pmset disablesleep` (admin) + IOKit stay-awake assertion | Previous sleep settings restored via a small watchdog |
| Works on **battery** without a monitor | Sleep is not left disabled after a clean quit |

`PreventSystemSleep` alone is not enough on battery; MacStayOn uses the same approach power users rely on for closed-lid work.

---

## Build from source

Developers and contributors:

```bash
brew install xcodegen
chmod +x scripts/build.sh
./scripts/build.sh
open dist/MacStayOn.app
```

Open in Xcode: `xcodegen generate && open MacStayOn.xcodeproj`

**Sign & notarize** (for your own Developer ID): see **[docs/DISTRIBUTE-MAC.md](docs/DISTRIBUTE-MAC.md)**.

---

## Verify (optional)

```bash
pmset -g | grep disablesleep    # 1 while On
pmset -g assertions | grep -i MacStayOn
spctl -a -vv dist/MacStayOn.app # Notarized Developer ID (after notarize.sh)
```

---

<p align="center">
  <sub>Menu bar · Local session analytics · Notarized macOS builds on Releases</sub>
</p>
