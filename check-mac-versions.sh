#!/bin/bash
#
# check-mac-versions.sh
# ----------------------
# Shows a swiftDialog (https://swiftdialog.app) list with:
#   - this Mac's current macOS version
#   - the latest macOS available, from SOFA (https://sofa.macadmins.io)
#   - the latest XProtect malware definitions and engine, also from SOFA
# Rows are green when this Mac is current and red when it is behind.
#
# When this Mac is behind the latest release of its own major (e.g. 26.6 when
# 26.7.1 is out) the user must Defer (1 hour, 2 hours, 4 hours or 1 day);
# there's no Done button to skip it. A newer major (e.g. 27) on its own is
# optional and just gets Done. The choice is saved to
# ~/Library/Preferences/local.check-mac-versions.plist
# and a LaunchAgent reruns this script with --deferred once it expires. After
# MAX_DEFER_COUNT deferrals the dialog can no longer be deferred or closed, and
# it keeps coming back until the Mac is updated. When the Mac is up to date,
# the saved deferral, the defer count and the LaunchAgent are all removed.
#
# JSON is parsed with osascript (JavaScript for Automation), so nothing beyond
# stock macOS + swiftDialog is required.
#
# Usage: check-mac-versions.sh             show the dialog now
#        check-mac-versions.sh --deferred  (LaunchAgent) show it only if a
#                                          saved deferral has expired
#        check-mac-versions.sh --reset     erase the defer count and any pending
#                                          reminder, remove the LaunchAgent, and
#                                          close the dialog if it's open
#
set -uo pipefail   # note: no -e — a failed fetch should degrade, not abort

case "${1:-}" in
  "")         MODE=manual ;;
  --deferred) MODE=deferred ;;
  --reset)    MODE=reset ;;
  *)          echo "Usage: $(basename "$0") [--deferred | --reset]" >&2; exit 2 ;;
esac

# ----------------------------------------------------------------------------
# Config
# ----------------------------------------------------------------------------
# Prefer the patched swiftDialog, which supports clickable ("url") and sparkling
# rows: first the copy installed by Dialog-Clickable.pkg, then a local build in
# ../swiftDialog-clickable. Otherwise use the stock swiftDialog. DIALOG_BIN
# overrides all of these (e.g. to test a new local build when the package is
# installed).
INSTALLED_PATCHED_DIALOG="/Library/Application Support/Dialog-Clickable/Dialog.app/Contents/MacOS/Dialog"
BUILT_PATCHED_DIALOG="$(cd "$(dirname "$0")/.." && pwd)/swiftDialog-clickable/Dialog.app/Contents/MacOS/Dialog"
if [ -n "${DIALOG_BIN:-}" ]; then
  DIALOG="$DIALOG_BIN"
elif [ -x "$INSTALLED_PATCHED_DIALOG" ]; then
  DIALOG="$INSTALLED_PATCHED_DIALOG"
elif [ -x "$BUILT_PATCHED_DIALOG" ]; then
  DIALOG="$BUILT_PATCHED_DIALOG"
else
  DIALOG="/usr/local/bin/dialog"
fi
CLICKABLE_ROWS=false
case "$DIALOG" in
  "$INSTALLED_PATCHED_DIALOG"|"$BUILT_PATCHED_DIALOG") CLICKABLE_ROWS=true ;;
esac
SOFA_URL="https://sofafeed.macadmins.io/v1/macos_data_feed.json"
USER_AGENT="check-mac-versions/1.0"   # SOFA asks clients to identify themselves
# System Settings ▸ General ▸ Software Update. Rows with an update open it
# alongside Apple's page (patched swiftDialog only).
SETTINGS_URL="x-apple.systempreferences:com.apple.Software-Update-Settings.extension"
CURL_TIMEOUT=20
FONT_SIZE=12
ICON_SIZE=90       # dialog icon (Apple logo), in points; swiftDialog default is 150
# Window width is sized to the longest list row; this is the room swiftDialog
# needs beyond the row text: the dialog icon column plus the row icon, status
# indicator and padding. MIN_WIDTH keeps short content from producing a cramped window.
WIDTH_OVERHEAD=$(( ICON_SIZE + 260 ))
WIN_HEIGHT=330
MIN_WIDTH=640

# Show the "Latest XProtect" row (true/false). Can also be set from the
# environment, e.g. SHOW_XPROTECT=false check-mac-versions.sh
SHOW_XPROTECT="${SHOW_XPROTECT:-true}"

# Highlight the uptime in bold red once the Mac has been up this many days.
UPTIME_WARN_DAYS=10

# "Create Ticket" button, bottom left. TICKET_ACTION is the URL it will open
# (e.g. the help desk's new-ticket page); empty means the button does nothing
# yet. An empty TICKET_BUTTON_TEXT hides the button.
TICKET_BUTTON_TEXT="Create Ticket"
TICKET_ACTION=""
# Hover text for the button (patched swiftDialog only).
TICKET_TOOLTIP="Use this if you are experiencing issues updating."

# Sound played as the dialog appears, as IBM Notifier does: a system sound name
# (Funk, Glass, Ping, …) or a path to a sound file. Empty means silent. Nothing
# plays when "Play user interface sound effects" is off in Sound settings.
POPUP_SOUND="Funk"

# When Done or Defer is pressed, the window slowly shrinks, then pops before closing
# (patched swiftDialog only; skipped when Reduce Motion is on). true or false.
CLOSE_EFFECT=true

# Deferral. The saved choice lives in the defaults domain below, i.e. the plist
# ~/Library/Preferences/$DEFER_DOMAIN.plist. The LaunchAgent checks it every
# AGENT_INTERVAL seconds and reruns this script once the deferral expires.
DEFER_DOMAIN="local.check-mac-versions"
DEFER_OPTIONS=("1 hour" "2 hours" "4 hours" "1 day")
# How many times the user may defer before the update is required. Written to
# the same plist as MaxDeferCount on every run; DeferCount there holds how many
# deferrals have been used. Only updating the Mac resets the count.
MAX_DEFER_COUNT=5
DEFER_HEIGHT=120   # extra window height for the "Defer for" radio list
AGENT_LABEL="local.check-mac-versions.defer"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
AGENT_INTERVAL=300
AGENT_LOG="$HOME/Library/Logs/check-mac-versions.log"
SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

TMPDIR_RUN="$(mktemp -d "${TMPDIR:-/tmp}/macver.XXXXXX")"
trap 'rm -rf "$TMPDIR_RUN"' EXIT
# Exit on a signal; the EXIT trap then cleans up. (A trap that only cleaned up
# would let the script carry on, e.g. reschedule the dialog after --reset.)
trap 'exit 130' INT
trap 'exit 143' TERM

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

# pad <version> <n>  -> version padded with ".0" to n components (26.7 -> 26.7.0)
pad() {
  local v="$1" want="$2" dots c
  dots="${v//[^.]/}"; c=$(( ${#dots} + 1 ))
  while [ "$c" -lt "$want" ]; do v="$v.0"; c=$((c+1)); done
  printf '%s' "$v"
}

# version_ge <a> <b>  -> true if a >= b, comparing 26.7 and 26.7.0 as equal
version_ge() {
  local a="$1" b="$2" da db ca cb max
  da="${a//[^.]/}"; db="${b//[^.]/}"
  ca=$(( ${#da} + 1 )); cb=$(( ${#db} + 1 ))
  max=$(( ca > cb ? ca : cb ))
  a="$(pad "$a" "$max")"; b="$(pad "$b" "$max")"
  [ "$a" = "$b" ] && return 0
  [ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -1)" = "$a" ]
}

# fetch <url> <file>  -> download, returns non-zero on failure
fetch() {
  curl -fsSL --max-time "$CURL_TIMEOUT" -A "$USER_AGENT" "$1" -o "$2" 2>/dev/null
}

# text_width <string>...  -> widest rendered width, in points, of the given
# strings in the system font (measured with AppKit, so it matches on-screen).
# Measured at 14pt — a size above the list font — to leave some slack.
text_width() {
  osascript -l JavaScript - "$@" <<'JXA' 2>/dev/null
ObjC.import("AppKit");
function run(argv) {
  var attrs = $.NSDictionary.dictionaryWithObjectForKey(
    $.NSFont.systemFontOfSize(14), $.NSFontAttributeName);
  var w = 0;
  argv.forEach(function (s) {
    w = Math.max(w, $.NSString.alloc.initWithUTF8String(s).sizeWithAttributes(attrs).width);
  });
  return Math.ceil(w);
}
JXA
}

# screen_width  -> usable width of the main display, in points
screen_width() {
  osascript -l JavaScript -e 'ObjC.import("AppKit"); Math.floor($.NSScreen.mainScreen.visibleFrame.size.width)' 2>/dev/null
}

# json_escape <text>  -> escape for embedding in a JSON string
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# defer_seconds <choice>  -> length of a defer choice in seconds, empty if unknown
defer_seconds() {
  case "$1" in
    "1 hour")  echo 3600 ;;
    "2 hours") echo 7200 ;;
    "4 hours") echo 14400 ;;
    "1 day")   echo 86400 ;;
  esac
}

# Separates a defer choice from its reopen time in the radio list labels.
DEFER_LABEL_SEP="  ·  "

# defer_label <choice>  -> "1 hour  ·  reopens at about 3:45 PM" (or "tomorrow at …"),
# when the dialog would come back if deferred now. "About" because the agent
# checks every AGENT_INTERVAL seconds.
defer_label() {
  local secs at day
  secs="$(defer_seconds "$1")"; [ -n "$secs" ] || { echo "$1"; return; }
  at=$(( $(date +%s) + secs ))
  day=""; [ "$(date -r "$at" +%Y%m%d)" != "$(date +%Y%m%d)" ] && day="tomorrow "
  echo "$1${DEFER_LABEL_SEP}reopens ${day}at about $(date -r "$at" '+%-I:%M %p')"
}

# plist_date <epoch>  -> date in the format `defaults write -date` accepts
plist_date() { date -u -r "$1" '+%Y-%m-%d %H:%M:%S +0000'; }

# install_agent  -> write and load the LaunchAgent that reruns this script
# with --deferred. Its content doesn't depend on the deferral time, so an
# agent that's already loaded is left running.
install_agent() {
  mkdir -p "$(dirname "$AGENT_PLIST")" "$(dirname "$AGENT_LOG")"
  cat > "$AGENT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$AGENT_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$SCRIPT_PATH</string>
    <string>--deferred</string>
  </array>
  <key>StartInterval</key><integer>$AGENT_INTERVAL</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$AGENT_LOG</string>
  <key>StandardErrorPath</key><string>$AGENT_LOG</string>
</dict>
</plist>
EOF
  launchctl print "gui/$(id -u)/$AGENT_LABEL" >/dev/null 2>&1 \
    || launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST"
}

# remove_agent  -> unload and delete the LaunchAgent. When this run was started
# by the agent, unloading it ends this run, so call it last.
remove_agent() {
  [ -f "$AGENT_PLIST" ] && rm -f "$AGENT_PLIST" && echo "Removed LaunchAgent $AGENT_LABEL"
  launchctl bootout "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null
  return 0
}

# defer_count  -> deferrals used so far (0 if none)
defer_count() {
  local n
  n="$(defaults read "$DEFER_DOMAIN" DeferCount 2>/dev/null)"
  [[ "$n" =~ ^[0-9]+$ ]] && echo "$n" || echo 0
}

# save_deferral <choice>  -> record the choice and its expiry, count it, start the agent
save_deferral() {
  local secs now until count
  secs="$(defer_seconds "$1")"; [ -n "$secs" ] || return 1
  now=$(date +%s); until=$(( now + secs ))
  count=$(( $(defer_count) + 1 ))
  defaults write "$DEFER_DOMAIN" DeferChoice -string "$1"
  defaults write "$DEFER_DOMAIN" DeferSetAt -date "$(plist_date "$now")"
  defaults write "$DEFER_DOMAIN" DeferUntil -date "$(plist_date "$until")"
  defaults write "$DEFER_DOMAIN" DeferUntilEpoch -int "$until"
  defaults write "$DEFER_DOMAIN" DeferCount -int "$count"
  echo "Deferred for $1, until $(date -r "$until" '+%Y-%m-%d %H:%M') ($count of $MAX_DEFER_COUNT deferrals used)"
  install_agent
}

# reopen_soon  -> have the agent reopen the dialog at its next check (an expiry
# of now means every check shows it). Used when deferrals are used up, and
# when the dialog was force-quit instead of deferred. Doesn't use a deferral.
reopen_soon() {
  local now
  now=$(date +%s)
  defaults write "$DEFER_DOMAIN" DeferUntil -date "$(plist_date "$now")"
  defaults write "$DEFER_DOMAIN" DeferUntilEpoch -int "$now"
  install_agent
}

# DEFER_KEYS: the pending deferral. DeferCount and MaxDeferCount are kept separately.
DEFER_KEYS=(DeferChoice DeferSetAt DeferUntil DeferUntilEpoch)

# clear_deferral  -> forget the pending deferral and remove the agent, but keep
# the defer count. Call last.
clear_deferral() {
  local key cleared=false
  for key in "${DEFER_KEYS[@]}"; do
    defaults read "$DEFER_DOMAIN" "$key" >/dev/null 2>&1 \
      && defaults delete "$DEFER_DOMAIN" "$key" >/dev/null 2>&1 && cleared=true
  done
  [ "$cleared" = true ] && echo "Cleared saved deferral"
  remove_agent
}

# reset_deferrals  -> the Mac is up to date: also reset the defer count. Call last.
reset_deferrals() {
  if defaults read "$DEFER_DOMAIN" DeferCount >/dev/null 2>&1; then
    defaults delete "$DEFER_DOMAIN" DeferCount >/dev/null 2>&1
    echo "Reset defer count"
  fi
  clear_deferral
}

# reset_all  -> --reset: close this script's dialog if it's open, then erase the
# defer count and pending reminder and remove the agent. Keeps MaxDeferCount.
reset_all() {
  local pid args dialogs
  # Stop other runs of this script first. A run waiting on its dialog would
  # otherwise treat the window closing as a Force Quit and reschedule it.
  # (The signal takes effect as soon as that run's dialog exits, below.)
  for pid in $(pgrep -f "$(basename "$SCRIPT_PATH")"); do
    args="$(ps -o args= -p "$pid" 2>/dev/null)"
    case "$args" in *--reset*|"") continue ;; esac
    kill "$pid" 2>/dev/null
  done
  dialogs="$(pgrep -f 'macver\..*/dialog\.json')"
  if [ -n "$dialogs" ]; then
    kill $dialogs 2>/dev/null && echo "Closed the open dialog"
    sleep 1
  fi
  reset_deferrals
  echo "Reset complete"
}

if [ "$MODE" = reset ]; then
  reset_all
  exit 0
fi

# ----------------------------------------------------------------------------
# Preconditions
# ----------------------------------------------------------------------------
if [ ! -x "$DIALOG" ]; then
  echo "swiftDialog not found at $DIALOG" >&2
  echo "Install it from https://swiftdialog.app (or: brew install --cask swift-dialog)" >&2
  exit 1
fi

# A scheduled (--deferred) run only carries on once the saved deferral has
# expired, and never while this script's dialog is already on screen.
if [ "$MODE" = deferred ]; then
  defer_until="$(defaults read "$DEFER_DOMAIN" DeferUntilEpoch 2>/dev/null)"
  if [ -z "$defer_until" ]; then
    remove_agent      # nothing pending, so the agent has nothing to do
    exit 0
  fi
  [ "$(date +%s)" -lt "$defer_until" ] && exit 0
  pgrep -f 'macver\..*/dialog\.json' >/dev/null && exit 0
fi

# ----------------------------------------------------------------------------
# This Mac
# ----------------------------------------------------------------------------
MAC_VER="$(sw_vers -productVersion)"
MAC_BUILD="$(sw_vers -buildVersion)"
MAC_MAJOR="${MAC_VER%%.*}"

# When this version was installed: the newest macOS entry for it in the install
# history, e.g. "Installed 6 October 2026 (15 days ago)". Blank if there's none
# (e.g. after an erase-and-install).
MAC_INSTALLED=""
installed_epoch="$(osascript -l JavaScript - "$MAC_VER" <<'JXA' 2>/dev/null
ObjC.import("Foundation");
function run(argv) {
  var history = ObjC.deepUnwrap($.NSArray.arrayWithContentsOfFile("/Library/Receipts/InstallHistory.plist")) || [];
  var latest = 0;
  history.forEach(function (e) {
    if (/^macOS/i.test(e.displayName || "") && e.displayVersion === argv[0] && e.date) {
      latest = Math.max(latest, e.date.getTime());
    }
  });
  return latest ? Math.floor(latest / 1000) : "";
}
JXA
)"
if [[ "$installed_epoch" =~ ^[0-9]+$ ]]; then
  days=$(( ( $(date +%s) - installed_epoch ) / 86400 ))
  case "$days" in
    0) ago="today" ;;
    1) ago="1 day ago" ;;
    *) ago="$days days ago" ;;
  esac
  MAC_INSTALLED="Installed $(date -r "$installed_epoch" '+%-d %B %Y') ($ago)"
fi

# The chip, as About This Mac shows it: "Chip: Apple M1". Intel Macs report a
# processor name instead ("Processor: Intel(R) Core(TM) i7-…").
MAC_CHIP=""
chip="$(sysctl -n machdep.cpu.brand_string 2>/dev/null)"
case "$chip" in
  "")      ;;
  Apple*)  MAC_CHIP="Chip: $chip" ;;
  *)       MAC_CHIP="Processor: $chip" ;;
esac

# Uptime, shown in the info box under the icon: "2 days, 12 hours".
# kern.boottime reads "{ sec = 1792418870, usec = … }".
# UPTIME_DAYS is the whole days, for the UPTIME_WARN_DAYS highlight.
plural() { [ "$1" -eq 1 ] && echo "1 $2" || echo "$1 ${2}s"; }
UPTIME_TEXT=""
UPTIME_DAYS=0
boot_epoch="$(sysctl -n kern.boottime 2>/dev/null | sed -n 's/.*sec = \([0-9]*\),.*/\1/p')"
if [[ "$boot_epoch" =~ ^[0-9]+$ ]]; then
  up=$(( $(date +%s) - boot_epoch ))
  UPTIME_DAYS=$(( up / 86400 ))
  UPTIME_TEXT="$(plural "$UPTIME_DAYS" day), $(plural $(( up % 86400 / 3600 )) hour)"
fi

# Installed XProtect: the malware definitions (XProtect.bundle, which SOFA calls
# XProtectPlistConfigData) and the scanning engine (XProtect.app, XProtectPayloads).
XP_DIR="/Library/Apple/System/Library/CoreServices"
XP_INST="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
  "$XP_DIR/XProtect.bundle/Contents/Info.plist" 2>/dev/null)"
XP_ENGINE_INST="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
  "$XP_DIR/XProtect.app/Contents/Info.plist" 2>/dev/null)"

# ----------------------------------------------------------------------------
# SOFA: latest release for this Mac's major version, and the newest major
# Prints: majorName \t majorVer \t majorBuild \t newestName \t newestVer \t newestBuild
#         \t newestURL \t majorURL (Apple's page for each release, from SOFA's SecurityInfo)
#         \t newestDate (release date of the newest macOS, e.g. 2026-09-28T00:00:00Z)
#         \t newestCVEs \t newestExploited (unique vulnerabilities resolved across
#            all releases of the newest major, and how many were actively exploited)
#         \t majorDate (release date of the latest release of this Mac's major)
#         \t majorCVEs \t majorExploited (as above, but only for the latest release
#            of this Mac's major, e.g. 26.7.1)
#         \t xpVer \t xpEngineVer \t xpDate (latest XProtect definitions and engine)
# ----------------------------------------------------------------------------
SOFA_JSON="$TMPDIR_RUN/sofa.json"
SOFA_LINE=""
if fetch "$SOFA_URL" "$SOFA_JSON"; then
  SOFA_LINE="$(osascript -l JavaScript - "$SOFA_JSON" "$MAC_MAJOR" <<'JXA' 2>/dev/null
ObjC.import("Foundation");
function run(argv) {
  var txt = $.NSString.stringWithContentsOfFileEncodingError(argv[0], 4, null).js;
  var feed = JSON.parse(txt);
  var os = feed.OSVersions;                         // newest major first
  var mine = os.find(function (o) { return o.OSVersion.split(" ").pop() === argv[1]; });
  var top = os[0];
  // Count each CVE once even if several releases of the major list it.
  // With ver, count only that release (e.g. 26.7.1), not the whole major.
  function vulns(o, ver) {
    var cves = {}, exploited = {};
    (o.SecurityReleases || []).forEach(function (r) {
      if (ver && r.ProductVersion !== ver) return;
      Object.keys(r.CVEs || {}).forEach(function (id) { cves[id] = true; });
      (r.ActivelyExploitedCVEs || []).forEach(function (id) { exploited[id] = true; });
    });
    return [Object.keys(cves).length, Object.keys(exploited).length];
  }
  var topV = vulns(top), mineV = mine ? vulns(mine, mine.Latest.ProductVersion) : ["", ""];
  var xpConf = feed.XProtectPlistConfigData || {}, xpPay = feed.XProtectPayloads || {};
  return [mine ? mine.OSVersion : "", mine ? mine.Latest.ProductVersion : "",
          mine ? mine.Latest.Build : "", top.OSVersion,
          top.Latest.ProductVersion, top.Latest.Build,
          top.Latest.SecurityInfo || "",
          mine ? (mine.Latest.SecurityInfo || "") : "",
          top.Latest.ReleaseDate || "",
          topV[0], topV[1],
          mine ? (mine.Latest.ReleaseDate || "") : "",
          mineV[0], mineV[1],
          xpConf["com.apple.XProtect"] || "",
          xpPay["com.apple.XProtectFramework.XProtect"] || "",
          xpConf.ReleaseDate || ""].join("\t");
}
JXA
)"
fi
IFS=$'\t' read -r MAJOR_NAME MAJOR_VER MAJOR_BUILD NEWEST_NAME NEWEST_VER NEWEST_BUILD NEWEST_URL MAJOR_URL NEWEST_DATE NEWEST_CVES NEWEST_EXPLOITED MAJOR_DATE MAJOR_CVES MAJOR_EXPLOITED XP_VER XP_ENGINE_VER XP_DATE <<< "$SOFA_LINE"
# "2026-09-28T00:00:00Z" -> "Released 28 September 2026" (blank if missing or unparseable)
released_text() {
  [ -n "$1" ] || return 0
  local d
  d="$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$1" "+%-d %B %Y" 2>/dev/null)"
  [ -n "$d" ] && echo "Released $d"
  return 0
}
NEWEST_RELEASED="$(released_text "$NEWEST_DATE")"
MAJOR_RELEASED="$(released_text "$MAJOR_DATE")"
XP_RELEASED="$(released_text "$XP_DATE")"
# "Vulnerabilities resolved: 242 (1 actively exploited)" (blank if SOFA had no data)
vulns_text() {   # <CVE count> <actively exploited count>
  [[ "$1" =~ ^[0-9]+$ ]] || return 0
  if [ "$1" -eq 0 ]; then
    echo "Vulnerabilities resolved: none published"
  elif [[ "$2" =~ ^[1-9][0-9]*$ ]]; then
    echo "Vulnerabilities resolved: $1 ($2 actively exploited)"
  else
    echo "Vulnerabilities resolved: $1"
  fi
}
# Newest: the whole major (an upgrade brings every fix since its .0).
# Latest: just that release, since this Mac already has the earlier ones.
NEWEST_VULNS="$(vulns_text "$NEWEST_CVES" "$NEWEST_EXPLOITED")"
MAJOR_VULNS="$(vulns_text "$MAJOR_CVES" "$MAJOR_EXPLOITED")"
# Only link to Apple's own support site; ignore anything else the feed carries.
case "$NEWEST_URL" in
  https://support.apple.com/*) ;;
  *) NEWEST_URL="" ;;
esac
case "$MAJOR_URL" in
  https://support.apple.com/*) ;;
  *) MAJOR_URL="" ;;
esac

# Is there a newer major macOS than this Mac's?
newer_major=false
[ -n "$NEWEST_VER" ] && [ "${NEWEST_VER%%.*}" -gt "$MAC_MAJOR" ] 2>/dev/null && newer_major=true

# ----------------------------------------------------------------------------
# Build the rows: "title|icon|status|statustext[|url[|sparkle[|subtitle[|tooltip]]]]"
# The tooltip is the row's hover text (patched swiftDialog only).
# Rows with an update get "sparkle": the patched swiftDialog twinkles them.
# "sparkle:<colour>" picks the colour (a swiftDialog colour name or #RRGGBB);
# plain "sparkle" is gold.
# A subtitle is smaller text under the title; SUB_SEP separates its lines.
SUB_SEP=$'\x1f'
# ----------------------------------------------------------------------------
ROWS=()

# 1. This Mac — green if it's on the latest release of its major, red if behind.
if [ -z "$MAJOR_VER" ]; then
  mac_status="pending"
elif version_ge "$MAC_VER" "$MAJOR_VER"; then
  mac_status="success"
else
  mac_status="fail"
fi
#    Its subtitle is when this version was installed and the chip.
mac_sub="$MAC_INSTALLED"
[ -n "$MAC_CHIP" ] && mac_sub="${mac_sub:+$mac_sub$SUB_SEP}$MAC_CHIP"
ROWS+=("This Mac|SF=desktopcomputer|$mac_status|macOS $MAC_VER ($MAC_BUILD)|||$mac_sub")

# 2. Latest release of this Mac's major, per SOFA.
if [ -n "$MAJOR_VER" ]; then
  # The row links to Apple's security-content page for that release; when
  # this Mac is behind, it also opens Software Update (links are
  # space-separated). Its subtitle is the release date and the
  # vulnerabilities that release resolved.
  major_sub="$MAJOR_RELEASED"
  [ -n "$MAJOR_VULNS" ] && major_sub="${major_sub:+$major_sub$SUB_SEP}$MAJOR_VULNS"
  major_link="$MAJOR_URL"
  if [ "$mac_status" = "fail" ]; then
    text="$MAJOR_VER ($MAJOR_BUILD)  ·  update available"
    major_link="$MAJOR_URL $SETTINGS_URL"
  else
    text="$MAJOR_VER ($MAJOR_BUILD)  ·  this Mac is current"
  fi
  # Red, to match the row's red status: this Mac is missing an update.
  major_sparkle=""; [ "$mac_status" = "fail" ] && major_sparkle="sparkle:red"
  ROWS+=("Latest macOS ${MAJOR_NAME} (SOFA)|SF=arrow.down.circle|$mac_status|$text|$major_link|$major_sparkle|$major_sub")
else
  ROWS+=("Latest macOS $MAC_MAJOR (SOFA)|SF=arrow.down.circle|pending|unavailable")
fi

# 3. Newest major macOS, per SOFA — a yellow warning ("error") when it's an
#    upgrade, rather than the red of a missing fix.
#    When it's newer than this Mac, the row also opens Software Update.
#    Its subtitle is the release date and the vulnerabilities it resolves.
if [ -n "$NEWEST_VER" ]; then
  # SOFA names end in the major number ("Golden Gate 27"), which the version
  # repeats, so show "Golden Gate 27.0.1" rather than "Golden Gate 27 27.0.1".
  newest_label="$NEWEST_NAME"
  [ "${NEWEST_NAME##* }" = "${NEWEST_VER%%.*}" ] && newest_label="${NEWEST_NAME% *}"
  newest_sub="$NEWEST_RELEASED"
  [ -n "$NEWEST_VULNS" ] && newest_sub="${newest_sub:+$newest_sub$SUB_SEP}$NEWEST_VULNS"
  if [ "$newer_major" = true ]; then
    ROWS+=("Newest macOS (SOFA)|SF=sparkles|error|$newest_label $NEWEST_VER ($NEWEST_BUILD)  ·  major upgrade|$NEWEST_URL $SETTINGS_URL|sparkle|$newest_sub")
  else
    ROWS+=("Newest macOS (SOFA)|SF=sparkles|success|$newest_label $NEWEST_VER ($NEWEST_BUILD)  ·  already on it|$NEWEST_URL||$newest_sub")
  fi
fi

# 4. Latest XProtect, per SOFA — the definitions and the engine must both be
#    current. macOS installs these in the background, so this row is
#    informational and doesn't affect the defer/required flow.
#    Its subtitle is the release date. Hidden when SHOW_XPROTECT isn't true;
#    WIN_HEIGHT was sized for it, so the window then shrinks by one row
#    (swiftDialog's row is the font size + 14, plus spacing).
#    Hovering over it explains what XProtect is.
XP_TOOLTIP="XProtect is Mac's built-in anti-malware and updates automatically."
if [ "$SHOW_XPROTECT" != true ]; then
  WIN_HEIGHT=$(( WIN_HEIGHT - (FONT_SIZE + 24) ))
elif [ -n "$XP_VER" ]; then
  if [ -z "$XP_INST" ]; then
    xp_status="pending"; xp_note="not installed"
  elif version_ge "$XP_INST" "$XP_VER" &&
       { [ -z "$XP_ENGINE_VER" ] || version_ge "${XP_ENGINE_INST:-0}" "$XP_ENGINE_VER"; }; then
    xp_status="success"; xp_note="this Mac is current"
  else
    xp_status="fail"; xp_note="this Mac has $XP_INST"
    [ -n "$XP_ENGINE_VER" ] && xp_note+=" (engine ${XP_ENGINE_INST:-none})"
  fi
  xp_text="$XP_VER"
  [ -n "$XP_ENGINE_VER" ] && xp_text+=" (engine $XP_ENGINE_VER)"
  ROWS+=("Latest XProtect (SOFA)|SF=checkmark.shield|$xp_status|$xp_text  ·  $xp_note|||$XP_RELEASED|$XP_TOOLTIP")
else
  ROWS+=("Latest XProtect (SOFA)|SF=checkmark.shield|pending|unavailable||||$XP_TOOLTIP")
fi

# ----------------------------------------------------------------------------
# Subtitle: only shown when a newer macOS exists, either a newer major release
# or a newer update for this Mac's own major. Blank otherwise. (swiftDialog
# shows placeholder text if the message is left out, so blank is a space.)
# ----------------------------------------------------------------------------
# UPDATE_STATE: "update" (this Mac is behind the latest release of its own
# major), "current", or "unknown" (SOFA couldn't be reached, so a saved
# deferral is left alone). Only "update" offers Defer. A newer major on its
# own is optional: the Mac counts as current and gets Done, though the
# subtitle still mentions it.
MESSAGE=" "
if [ "$mac_status" = "fail" ]; then
  UPDATE_STATE=update
elif [ -n "$MAJOR_VER" ]; then
  UPDATE_STATE=current
else
  UPDATE_STATE=unknown
fi
if [ "$mac_status" = "fail" ] || [ "$newer_major" = true ]; then
  if [ "$CLICKABLE_ROWS" = true ]; then
    MESSAGE="There is a new macOS version available. Please click on the row to learn more."
  else
    MESSAGE="There is a new macOS version available."
  fi
fi

# Deferrals used up: the update is required and the dialog can't be dismissed.
DEFER_COUNT="$(defer_count)"
DEFERS_LEFT=$(( MAX_DEFER_COUNT - DEFER_COUNT ))
[ "$DEFERS_LEFT" -lt 0 ] && DEFERS_LEFT=0
REQUIRED=false
if [ "$UPDATE_STATE" = update ] && [ "$DEFERS_LEFT" -eq 0 ]; then
  REQUIRED=true
  if [ "$CLICKABLE_ROWS" = true ]; then
    MESSAGE="This update is now required: it has been deferred the maximum of $MAX_DEFER_COUNT times. Please click on the row to open Software Update and update now."
  else
    MESSAGE="This update is now required: it has been deferred the maximum of $MAX_DEFER_COUNT times. Please update now in System Settings ▸ General ▸ Software Update."
  fi
fi

# ----------------------------------------------------------------------------
# Show the dialog
# ----------------------------------------------------------------------------
li_json=""
row_texts=()   # each row's title + status text, as they sit side by side
subtitle_rows=0
subtitle_lines=0
for row in "${ROWS[@]}"; do
  IFS='|' read -r t icon st txt url sp sub tip <<< "$row"
  [ -n "$li_json" ] && li_json+=","
  extra_json=""
  [ -n "$url" ] && extra_json=",\"url\":\"$(json_escape "$url")\""
  [ -n "$tip" ] && extra_json+=",\"tooltip\":\"$(json_escape "$tip")\""
  case "$sp" in
    sparkle)   extra_json+=",\"sparkle\":true" ;;
    sparkle:*) extra_json+=",\"sparkle\":true,\"sparklecolour\":\"$(json_escape "${sp#sparkle:}")\"" ;;
  esac
  if [ -n "$sub" ]; then
    # SUB_SEP becomes a JSON newline (escaped after the rest of the text is).
    sub_json="$(json_escape "$sub")"
    extra_json+=",\"subtitle\":\"${sub_json//$SUB_SEP/\\n}\""
    seps="${sub//[^$SUB_SEP]/}"
    subtitle_rows=$(( subtitle_rows + 1 ))
    subtitle_lines=$(( subtitle_lines + ${#seps} + 1 ))
  fi
  li_json+="{\"title\":\"$(json_escape "$t")\",\"icon\":\"$(json_escape "$icon")\",\"status\":\"$st\",\"statustext\":\"$(json_escape "$txt")\"$extra_json}"
  row_texts+=("$t      $txt")
done

# Make room for subtitles. In the patched swiftDialog a row with a subtitle
# only grows to fit its text, so add one small line's height per subtitle
# line; more leaves an empty-looking row at the bottom of the list. The stock
# swiftDialog makes every row 28pt taller (icons too, room for two lines) once
# any row has one.
SUBTITLE_LINE_HEIGHT_PATCHED=12
SUBTITLE_ROW_HEIGHT_STOCK=28
if [ "$subtitle_rows" -gt 0 ]; then
  if [ "$CLICKABLE_ROWS" = true ]; then
    WIN_HEIGHT=$(( WIN_HEIGHT + subtitle_lines * SUBTITLE_LINE_HEIGHT_PATCHED ))
  else
    WIN_HEIGHT=$(( WIN_HEIGHT + ${#ROWS[@]} * SUBTITLE_ROW_HEIGHT_STOCK ))
  fi
fi

# Info box (under the icon): the uptime, in Markdown with a hard line break.
# swiftDialog widens the icon column to at least INFOBOX_MIN_WIDTH for it, so
# the window grows by the difference to keep the rows from being cut off.
# The patched build sets it level with the last row (Latest XProtect, when
# shown), centred under the icon, in the rows' font size.
INFOBOX_MIN_WIDTH=150
INFOBOX_JSON=""
infobox_extra=0
if [ -n "$UPTIME_TEXT" ]; then
  uptime_md="$(json_escape "$UPTIME_TEXT")"
  # Up too long: bold red highlight on the patched build (it shows `code` spans
  # in the infoboxhighlight colour), just bold on stock swiftDialog.
  if [ "$UPTIME_DAYS" -ge "$UPTIME_WARN_DAYS" ]; then
    if [ "$CLICKABLE_ROWS" = true ]; then
      uptime_md="\`$uptime_md\`"
      INFOBOX_JSON="\"infoboxhighlight\": \"red\","
    else
      uptime_md="**$uptime_md**"
    fi
  fi
  INFOBOX_JSON+="\"infobox\": \"**Uptime**  \\n$uptime_md\","
  [ "$CLICKABLE_ROWS" = true ] && INFOBOX_JSON+="
  \"infoboxrow\": \"$(( ${#ROWS[@]} - 1 ))\",
  \"infoboxcentre\": true,"
  [ "$ICON_SIZE" -lt "$INFOBOX_MIN_WIDTH" ] && infobox_extra=$(( INFOBOX_MIN_WIDTH - ICON_SIZE ))
fi

# Fit the window to the widest row, within [MIN_WIDTH, screen width].
text_w="$(text_width "${row_texts[@]}")"
WIN_WIDTH=$(( ${text_w:-400} + WIDTH_OVERHEAD + infobox_extra ))
[ "$WIN_WIDTH" -lt "$MIN_WIDTH" ] && WIN_WIDTH=$MIN_WIDTH
max_w="$(screen_width)"; max_w=$(( ${max_w:-1440} - 40 ))
[ "$WIN_WIDTH" -gt "$max_w" ] && WIN_WIDTH=$max_w

# The info button (bottom left) is "Create Ticket" when TICKET_BUTTON_TEXT is
# set. TICKET_ACTION is the URL it opens; while it's empty the button does
# nothing (an empty action keeps swiftDialog from closing the dialog on click).
#
# Otherwise, the patched build makes the "Newest macOS" row itself a link. The
# stock swiftDialog can't click rows, so there the link goes on the info button
# instead; opening it keeps the dialog up.
INFO_JSON=""
if [ -n "$TICKET_BUTTON_TEXT" ]; then
  INFO_JSON="\"infobuttontext\": \"$(json_escape "$TICKET_BUTTON_TEXT")\",
  \"infobuttonaction\": \"$(json_escape "$TICKET_ACTION")\","
  # Centred under the icon, in line with the uptime (patched swiftDialog only).
  [ "$CLICKABLE_ROWS" = true ] && INFO_JSON+="
  \"infobuttoncentre\": true,"
  [ "$CLICKABLE_ROWS" = true ] && [ -n "$TICKET_TOOLTIP" ] && INFO_JSON+="
  \"infobuttontooltip\": \"$(json_escape "$TICKET_TOOLTIP")\","
elif [ -n "$NEWEST_URL" ] && [ "$CLICKABLE_ROWS" != true ]; then
  # SOFA names end in the major number ("Golden Gate 27"); drop it so the label
  # reads like Apple's own: "macOS Golden Gate 27.0.1".
  INFO_JSON="\"infobuttontext\": \"$(json_escape "macOS ${NEWEST_NAME% *} $NEWEST_VER on Apple Support")\",
  \"infobuttonaction\": \"$(json_escape "$NEWEST_URL")\","
fi

# When there's an update, the window can't be dismissed without deciding:
# Done is hidden ("none"), Return/Esc do nothing (so a stray key press can't
# use up a deferral), and the quit key is a control character no key
# combination types, which disables Cmd+Q. Force Quit still works; the
# LaunchAgent then reopens the dialog within 5 minutes.
#
# The only button is then Defer, with a "Defer for" radio list. alwaysreturninput
# makes swiftDialog report the chosen option for it (normally it only does for
# button 1). When the deferrals are used up there's no Defer either.
LOCK_JSON="\"hidedefaultkeyboardaction\": true,
  \"quitkey\": \"\\u0001\","
DEFER_JSON=""
BUTTON1_TEXT="Done"
# The window can be dragged, except once the update is required. swiftDialog
# makes it movable whenever the key is present, so it's left out then.
MOVEABLE_JSON="\"moveable\": true,"
# Camera button in the top-right corner that saves a screenshot of the window
# (patched swiftDialog only).
SCREENSHOT_JSON=""
[ "$CLICKABLE_ROWS" = true ] && SCREENSHOT_JSON="\"screenshotbutton\": true,"
# The patched build plays POPUP_SOUND itself as the window appears.
[ "$CLICKABLE_ROWS" = true ] && [ -n "$POPUP_SOUND" ] && SCREENSHOT_JSON+="
  \"popupsound\": \"$(json_escape "$POPUP_SOUND")\","
[ "$CLICKABLE_ROWS" = true ] && [ "$CLOSE_EFFECT" = true ] && SCREENSHOT_JSON+="
  \"closeeffect\": true,"
# Everything up to date (every row green): a green trail circles the list
# (patched swiftDialog only).
all_green=true
for row in "${ROWS[@]}"; do
  IFS='|' read -r _ _ st _ <<< "$row"
  [ "$st" = success ] || all_green=false
done
[ "$CLICKABLE_ROWS" = true ] && [ "$all_green" = true ] && SCREENSHOT_JSON+="
  \"listtrail\": \"green\","
if [ "$REQUIRED" = true ]; then
  BUTTON1_TEXT="none"
  DEFER_JSON="$LOCK_JSON"
  MOVEABLE_JSON=""
elif [ "$UPDATE_STATE" = update ]; then
  BUTTON1_TEXT="none"
  # Each option shows when the dialog would reopen if chosen.
  values=""
  for opt in "${DEFER_OPTIONS[@]}"; do values+="${values:+, }\"$(json_escape "$(defer_label "$opt")")\""; done
  DEFER_JSON="$LOCK_JSON
  \"button2text\": \"Defer\",
  \"alwaysreturninput\": true,
  \"selectitems\": [ { \"title\": \"Defer for ($DEFERS_LEFT of $MAX_DEFER_COUNT left)\", \"values\": [ $values ], \"default\": \"$(json_escape "$(defer_label "${DEFER_OPTIONS[0]}")")\", \"style\": \"radio\" } ],"
  WIN_HEIGHT=$(( WIN_HEIGHT + DEFER_HEIGHT ))
fi

JSON="$TMPDIR_RUN/dialog.json"
cat > "$JSON" <<EOF
{
  "title": "macOS & XProtect Version Check",
  "message": "$(json_escape "$MESSAGE")",
  "messagefont": "size=$FONT_SIZE",
  "icon": "SF=apple.logo",
  "iconsize": $ICON_SIZE,
  $INFOBOX_JSON
  "button1text": "$BUTTON1_TEXT",
  $INFO_JSON
  $DEFER_JSON
  $MOVEABLE_JSON
  $SCREENSHOT_JSON
  "ontop": true,
  "width": $WIN_WIDTH,
  "height": $WIN_HEIGHT,
  "listitem": [ $li_json ]
}
EOF

# Plain-text summary for logs / non-GUI runs.
printf '\nmacOS & XProtect Version Check — %s\n' "$(date '+%Y-%m-%d %H:%M')"
for row in "${ROWS[@]}"; do
  IFS='|' read -r t icon st txt url sp sub tip <<< "$row"
  sub="${sub//$SUB_SEP/ · }"
  printf '  [%-7s] %s — %s%s%s\n' "$st" "$t" "$txt" "${sub:+  ($sub)}" "${url:+  <$url>}"
done
echo

# Record the limit alongside the deferral state.
defaults write "$DEFER_DOMAIN" MaxDeferCount -int "$MAX_DEFER_COUNT"

# Up to date: forget any deferral and reset the count, so the user isn't
# reminded unnecessarily. A scheduled run then stops here without showing
# anything. (This unloads the agent, which ends a run the agent started, so
# it comes last.)
if [ "$UPDATE_STATE" = current ] && [ "$MODE" = deferred ]; then
  reset_deferrals
  exit 0
fi
# SOFA unreachable on a scheduled run: keep the deferral and try again later.
[ "$UPDATE_STATE" = unknown ] && [ "$MODE" = deferred ] && exit 0

# Required: make sure the dialog keeps coming back, even after a Force Quit.
# The deferral count is only reported when an update is needed.
if [ "$REQUIRED" = true ]; then
  reopen_soon
  echo "Deferrals used: $DEFER_COUNT of $MAX_DEFER_COUNT (update required)"
elif [ "$UPDATE_STATE" = update ]; then
  echo "Deferrals used: $DEFER_COUNT of $MAX_DEFER_COUNT"
fi

# Stock swiftDialog can't play a sound, so play POPUP_SOUND here as it opens,
# unless interface sound effects are turned off.
if [ "$CLICKABLE_ROWS" != true ] && [ -n "$POPUP_SOUND" ] &&
   [ "$(defaults read -g com.apple.sound.uiaudio.enabled 2>/dev/null)" != 0 ]; then
  sound_file="$POPUP_SOUND"
  case "$sound_file" in */*) ;; *) sound_file="/System/Library/Sounds/$POPUP_SOUND.aiff" ;; esac
  [ -f "$sound_file" ] && ( sleep 0.5; afplay "$sound_file" ) >/dev/null 2>&1 &
fi

# Show the dialog. Exit code 2 is the Defer button; --json prints the choice.
DIALOG_OUT="$("$DIALOG" --jsonfile "$JSON" --json 2>/dev/null)"
DIALOG_RC=$?

case "$UPDATE_STATE" in
  update)
    if [ "$REQUIRED" = true ]; then
      :                  # can only end by Force Quit or the restart; agent stays
    elif [ "$DIALOG_RC" -eq 2 ]; then
      choice="$(printf '%s' "$DIALOG_OUT" | plutil -extract SelectedOption raw -o - - 2>/dev/null)"
      choice="${choice%%"$DEFER_LABEL_SEP"*}"   # drop the "reopens at …" part
      # The radio list always has a selection; fall back to the shortest if not.
      [ -n "$(defer_seconds "$choice")" ] || choice="${DEFER_OPTIONS[0]}"
      save_deferral "$choice"
    else
      # No Done button, so this was a Force Quit: don't let it skip the
      # decision. Bring the dialog back without using a deferral.
      echo "Dialog closed without a deferral (exit code $DIALOG_RC); reopening at the next check"
      reopen_soon
    fi
    ;;
  current)
    reset_deferrals
    ;;
esac
exit 0
