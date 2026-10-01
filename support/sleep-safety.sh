#!/bin/bash
# Root safety net (LaunchDaemon): if SleepDisabled=1 but no live MacStayOn
# watchdog remains, restore normal lid sleep. Covers SIGKILL of app+watchdog.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

val="$(pmset -g 2>/dev/null | awk 'BEGIN{IGNORECASE=1} $1=="SleepDisabled" || $1=="disablesleep" {print $2; exit}')"
if [ "$val" != "1" ]; then
  exit 0
fi

for dir in /tmp/MacStayOn-*; do
  [ -d "$dir" ] || continue
  for f in "$dir/watchdog.pid" "$dir/watchdog.ready"; do
    [ -f "$f" ] || continue
    pid="$(cat "$f" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      exit 0
    fi
  done
done

/usr/bin/pmset -a disablesleep 0
/usr/bin/logger -t MacStayOn "sleep-safety restored SleepDisabled (no live watchdog)"
exit 0
