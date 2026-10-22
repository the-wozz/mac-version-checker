# mac-version-checker

A [swiftDialog](https://swiftdialog.app) script that shows whether a Mac is up to date, and nudges the user to update it with deferrals that eventually run out.

It lists:

| Row | What it shows |
|---|---|
| **This Mac** | The installed macOS version and build, when it was installed, and the chip |
| **Latest macOS** | The latest release of the Mac's own major version, with its release date and the vulnerabilities it resolved |
| **Newest macOS** | The newest major version, e.g. an upgrade from Tahoe 26 to Golden Gate 27 |
| **Latest XProtect** | The latest XProtect malware definitions and engine, compared with the installed ones |

Rows are green when the Mac is current, red when it's missing an update, and yellow when only an optional major upgrade is available. The info box under the icon shows the Mac's uptime, in red once it has been up for 10 days or more.

All version data comes from the [SOFA](https://sofa.macadmins.io) feed (`sofafeed.macadmins.io`). JSON is parsed with JavaScript for Automation (`osascript`), so nothing beyond stock macOS and swiftDialog is needed.

## Requirements

- macOS on Apple silicon or Intel
- [swiftDialog](https://github.com/swiftDialog/swiftDialog/releases) 2.5 or later, installed at `/usr/local/bin/dialog`

## Usage

```bash
./check-mac-versions.sh             # show the dialog now
./check-mac-versions.sh --deferred  # (used by the LaunchAgent) show it only once a saved deferral has expired
./check-mac-versions.sh --reset     # erase the defer count and any pending reminder, remove the LaunchAgent, close the dialog
```

## Deferrals

When the Mac is behind the latest release of its **own** major version (for example 26.6 when 26.7.1 is out), there's no Done button: the user must choose **Defer** for 1 hour, 2 hours, 4 hours or 1 day. Each option shows when the dialog will reopen. A newer major version on its own is optional and just gets **Done**.

- **Where it's saved:** the choice goes to `~/Library/Preferences/local.check-mac-versions.plist`. A LaunchAgent, `~/Library/LaunchAgents/local.check-mac-versions.defer.plist`, checks every 5 minutes and reopens the dialog once the deferral expires. The agent logs to `~/Library/Logs/check-mac-versions.log`.
- **When deferrals run out:** after `MAX_DEFER_COUNT` deferrals (5 by default), the update is required. The dialog can't be deferred, closed or moved, and it keeps coming back until the Mac is updated.
- **Once the Mac is updated:** the saved deferral, the count and the LaunchAgent are removed automatically.

## Settings

The settings are variables near the top of the script:

| Setting | Default | What it does |
|---|---|---|
| `MAX_DEFER_COUNT` | `5` | How many times the user may defer before the update is required |
| `DEFER_OPTIONS` | `1 hour`, `2 hours`, `4 hours`, `1 day` | The defer choices |
| `SHOW_XPROTECT` | `true` | Show the Latest XProtect row (can also be set in the environment) |
| `UPTIME_WARN_DAYS` | `10` | Uptime, in days, at which the info box turns red |
| `TICKET_BUTTON_TEXT` | `Create Ticket` | Bottom-left button; empty hides it |
| `TICKET_ACTION` | *(empty)* | URL the ticket button opens; empty does nothing yet |
| `POPUP_SOUND` | `Funk` | Sound played when the dialog appears, like IBM Notifier; empty is silent |
| `CLOSE_EFFECT` | `true` | Shrink-and-pop animation when Done or Defer is pressed |
| `FONT_SIZE`, `ICON_SIZE` | `12`, `90` | Text and icon size |

`POPUP_SOUND` is skipped when **Play user interface sound effects** is turned off in Sound settings.

## Optional: patched swiftDialog

Several touches need a patched build of swiftDialog: clickable rows that open Apple's security notes and Software Update, sparkles, tooltips, the screenshot button, the green "all up to date" trail and the close effect. The script uses a patched build when it finds one at `/Library/Application Support/Dialog-Clickable/Dialog.app`. Otherwise it falls back to the stock `/usr/local/bin/dialog` and leaves those features out. A different build can be chosen with `DIALOG_BIN=/path/to/Dialog`.
