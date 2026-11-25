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
    """

    static let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
    	<key>Label</key>
    	<string>com.markdebartolo.MacStayOn.sleep-safety</string>
    	<key>AssociatedBundleIdentifiers</key>
    	<string>com.markdebartolo.MacStayOn</string>
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

    /// Stages the daemon files for the root enable script to copy into /Library.
    /// The shared /tmp state dir can be left missing or root-owned by an earlier
    /// session, so fall back to a fresh per-user temp dir (root can read either).
    static func writeStagingFiles(to directory: URL) throws -> (script: URL, plist: URL) {
        do {
            return try writeStagingFilesOrThrow(to: directory)
        } catch let primaryError {
            let fallbackDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("MacStayOn-staging-\(UUID().uuidString)", isDirectory: true)
            do {
                return try writeStagingFilesOrThrow(to: fallbackDirectory)
            } catch {
                throw primaryError
            }
        }
    }

    private static func writeStagingFilesOrThrow(to directory: URL) throws -> (script: URL, plist: URL) {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let scriptURL = directory.appendingPathComponent(scriptName)
        let plistURL = directory.appendingPathComponent(plistName)
        try writeFile(script, to: scriptURL, permissions: 0o755)
        try writeFile(plist, to: plistURL, permissions: 0o644)
        return (scriptURL, plistURL)
    }

    /// Writes a small text file in place. Deliberately not an atomic write: these
    /// files gain nothing from the extra temporary-item step, and it is one more
    /// thing that can fail right before an admin prompt. A stale copy (possibly
    /// root-owned, left by an earlier privileged session) is removed first so it
    /// cannot block the new one.
    static func writeFile(_ text: String, to fileURL: URL, permissions: Int) throws {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: fileURL)
        try Data(text.utf8).write(to: fileURL)
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: fileURL.path)
    }
}
