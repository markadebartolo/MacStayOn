import Foundation

/// Files installed into `/Library` on first successful Turn On (admin) so a
/// LaunchDaemon can restore lid sleep after SIGKILL of app + watchdog.
/// While Stay Awake is Off and sleep is normal, the daemon uninstalls itself
/// so Off never leaves durable privileged leftovers.
enum SleepSafetyResources {
    static let scriptName = "sleep-safety.sh"
    static let plistName = "sleep-safety.plist"
    static let launchdLabel = "com.markdebartolo.MacStayOn.sleep-safety"

    static let script = """
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
      /bin/launchctl bootout "system/${LABEL}" 2>/dev/null || true
      rm -f "$PLIST"
      rm -rf "$SAFETY_DIR"
      /usr/bin/logger -t MacStayOn "sleep-safety uninstalled (Off / normal lid sleep)"
    }

    val="$(pmset -g 2>/dev/null | awk 'BEGIN{IGNORECASE=1} $1=="SleepDisabled" || $1=="disablesleep" {print $2; exit}')"

    if [ "$val" != "1" ]; then
      # Sleep already normal — drop durable root leftovers once Stay Awake is gone.
      if ! any_live_watchdog; then
        uninstall_self
      fi
      exit 0
    fi

    if any_live_watchdog; then
      exit 0
    fi

    /usr/bin/pmset -a disablesleep 0
    /usr/bin/logger -t MacStayOn "sleep-safety restored SleepDisabled (no live watchdog)"
    # Next StartInterval / RunAtLoad will uninstall once SleepDisabled reads 0.
    exit 0
    """

    static let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
    	<key>Label</key>
    	<string>com.markdebartolo.MacStayOn.sleep-safety</string>
    	<key>ProgramArguments</key>
    	<array>
    		<string>/bin/bash</string>
    		<string>/Library/Application Support/MacStayOn/sleep-safety.sh</string>
    	</array>
    	<key>RunAtLoad</key>
    	<true/>
    	<key>StartInterval</key>
    	<integer>60</integer>
    	<key>Nice</key>
    	<integer>5</integer>
    </dict>
    </plist>
    """

    /// Shell fragment (root) that boots out and deletes the sleep-safety LaunchDaemon.
    static let uninstallShell = """
    /bin/launchctl bootout system/com.markdebartolo.MacStayOn.sleep-safety 2>/dev/null || true
    /bin/rm -f /Library/LaunchDaemons/com.markdebartolo.MacStayOn.sleep-safety.plist
    /bin/rm -rf "/Library/Application Support/MacStayOn"
    """

    static func writeStagingFiles(to directory: URL) throws -> (script: URL, plist: URL) {
        let scriptURL = directory.appendingPathComponent(scriptName)
        let plistURL = directory.appendingPathComponent(plistName)
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        try plist.write(to: plistURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plistURL.path)
        return (scriptURL, plistURL)
    }
}
