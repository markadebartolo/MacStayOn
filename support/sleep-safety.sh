#!/bin/bash
# Root safety net (LaunchDaemon): if SleepDisabled=1 but no live MacStayOn
# watchdog remains, restore normal lid sleep. Covers SIGKILL of app+watchdog.
# When sleep is already normal and no watchdog is live, uninstall this daemon
# so Off never leaves durable privileged force-awake leftovers.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

LABEL="com.markdebartolo.MacStayOn.sleep-safety"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
SAFETY_DIR="/Library/Application Support/MacStayOn"

# True only when pid is a live MacStayOn watchdog (not a recycled unrelated pid).
watchdog_pid_is_live() {
  local pid="$1"
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  local args
  args="$(ps -p "$pid" -o args= 2>/dev/null || true)"
  case "$args" in
    *watchdog.py*|*MacStayOn*) return 0 ;;
  esac
  return 1
}

any_live_watchdog() {
  local dir f pid
  for dir in /tmp/MacStayOn-*; do
    [ -d "$dir" ] || continue
    for f in "$dir/watchdog.pid" "$dir/watchdog.ready"; do
      [ -f "$f" ] || continue
      pid="$(tr -d '[:space:]' < "$f" 2>/dev/null || true)"
      if watchdog_pid_is_live "$pid"; then
        return 0
      fi
    done
  done
  return 1
}

uninstall_self() {
  # Delete the files FIRST: `launchctl bootout` of our own label kills this
  # script on the spot, so anything after it never runs (the plist would
  # survive and reload at every boot).
  rm -f "$PLIST"
  rm -rf "$SAFETY_DIR"
  /usr/bin/logger -t MacStayOn "sleep-safety uninstalled (Off / normal lid sleep)"
  /bin/launchctl bootout "system/${LABEL}" 2>/dev/null || true
}

val="$(pmset -g 2>/dev/null | awk 'BEGIN{IGNORECASE=1} $1=="SleepDisabled" || $1=="disablesleep" {print $2; exit}')"

if [ "$val" != "1" ]; then
  # Sleep already normal — drop durable root leftovers once Stay Awake is gone.
  if ! any_live_watchdog; then
    uninstall_self
  fi
  exit 0
fi

# Off asked for a restore (sentinel) long ago, yet sleep is still disabled: the
# watchdog is alive but not doing its job. Restore anyway — this file can only
# ever make the Mac sleep normally, never keep it awake.
stale_restore_request() {
  local dir s now mtime
  now="$(date +%s)"
  for dir in /tmp/MacStayOn-*; do
    s="$dir/restore.sentinel"
    [ -f "$s" ] || continue
    mtime="$(stat -f %m "$s" 2>/dev/null || echo "$now")"
    if [ $((now - mtime)) -ge 20 ]; then
      return 0
    fi
  done
  return 1
}

if stale_restore_request; then
  /usr/bin/pmset -a disablesleep 0
  /usr/bin/logger -t MacStayOn "sleep-safety restored SleepDisabled (watchdog ignored Off request)"
  exit 0
fi

if any_live_watchdog; then
  exit 0
fi

/usr/bin/pmset -a disablesleep 0
/usr/bin/logger -t MacStayOn "sleep-safety restored SleepDisabled (no live watchdog)"
# Next StartInterval / RunAtLoad will uninstall once SleepDisabled reads 0.
exit 0
