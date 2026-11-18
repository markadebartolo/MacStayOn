import Foundation

/// Source text for everything MacStayOn runs as root: the watchdog, the Turn On
/// script, and the restore command. Kept apart from `SleepAssertionManager` so the
/// exact text that ships can be linted and exercised by the test suite.
enum PrivilegedScripts {
    static let watchdogFileName = "watchdog.py"
    static let enableScriptFileName = "enable-watchdog.sh"

    /// Root watchdog. Survives the auth dialog (setsid + ignore SIGHUP) and restores
    /// `disablesleep 0` when Off drops a sentinel, when the app process exits, or
    /// when it is asked to stop (SIGTERM) — no second password.
    /// Always restores to 0 (never re-applies a stuck SleepDisabled=1 as "previous").
    ///
    /// Arguments: <state dir> <app pid> <session id>
    static let watchdogPython = """
    #!/usr/bin/env python3
    import errno, os, shutil, signal, subprocess, sys, time

    state = sys.argv[1]
    app_pid = int(sys.argv[2])
    session = sys.argv[3]
    sentinel = os.path.join(state, "restore.sentinel")
    prev = os.path.join(state, "disablesleep.prev")
    pid_file = os.path.join(state, "watchdog.pid")
    ready_file = os.path.join(state, "watchdog.ready")
    session_file = os.path.join(state, "session.id")
    log_path = os.path.join(state, "watchdog.log")

    PMSET = "/usr/bin/pmset"
    LAUNCHCTL = "/bin/launchctl"
    SAFETY_LABEL = "com.markdebartolo.MacStayOn.sleep-safety"
    SAFETY_PLIST = "/Library/LaunchDaemons/" + SAFETY_LABEL + ".plist"
    SAFETY_DIR = "/Library/Application Support/MacStayOn"
    REQUIRE_ROOT = True

    def log(msg):
        try:
            with open(log_path, "a") as f:
                f.write(msg + "\\n")
        except OSError:
            pass

    def pid_alive(pid):
        try:
            os.kill(pid, 0)
            return True
        except ProcessLookupError:
            return False
        except PermissionError:
            return True
        except OSError as e:
            if e.errno == errno.ESRCH:
                return False
            if e.errno == errno.EPERM:
                return True
            return False

    def session_is_current():
        try:
            with open(session_file, "r") as f:
                return f.read().strip() == session
        except OSError:
            return False

    try:
        os.setsid()
    except OSError:
        pass
    # Survive AppleScript's admin shell exit (SIGHUP).
    signal.signal(signal.SIGHUP, signal.SIG_IGN)

    # A polite stop request (SIGTERM — shutdown, `killall`) must still restore lid
    # sleep instead of dying with SleepDisabled=1. Turn On replaces a stale
    # watchdog with SIGKILL after claiming the session, so this cannot undo it.
    stop_requested = False
    def request_stop(signum, frame):
        global stop_requested
        stop_requested = True
    signal.signal(signal.SIGTERM, request_stop)

    # Detach stdio so the privileged parent shell can exit cleanly.
    try:
        devnull = open(os.devnull, "r+")
        os.dup2(devnull.fileno(), 0)
        os.dup2(devnull.fileno(), 1)
        os.dup2(devnull.fileno(), 2)
    except OSError:
        pass

    euid = os.geteuid()
    log("watchdog start app=%s euid=%s session=%s" % (app_pid, euid, session))
    if REQUIRE_ROOT and euid != 0:
        log("FATAL: watchdog is not root — cannot restore pmset; exiting")
        try:
            with open(os.path.join(state, "watchdog.notroot"), "w") as f:
                f.write(str(euid))
        except OSError:
            pass
        sys.exit(2)
    try:
        with open(ready_file, "w") as f:
            f.write(str(os.getpid()))
    except OSError:
        pass

    while True:
        alive = pid_alive(app_pid)
        if (not alive) or stop_requested or os.path.exists(sentinel):
            log("restore sleep app_alive=%s sentinel=%s stop=%s euid=%s" % (
                alive, os.path.exists(sentinel), stop_requested, os.geteuid()))
            break
        time.sleep(0.25)

    # A newer Turn On owns SleepDisabled — do not undo it.
    if not session_is_current():
        log("skip restore — session superseded")
        for p in (pid_file, ready_file):
            try:
                os.remove(p)
            except OSError:
                pass
        sys.exit(0)

    rc = 1
    for attempt in range(5):
        try:
            rc = subprocess.call([PMSET, "-a", "disablesleep", "0"])
        except OSError as e:
            log("pmset restore failed to launch: %s" % e)
            rc = 1
        log("pmset restore rc=%s attempt=%s" % (rc, attempt + 1))
        if rc == 0:
            break
        time.sleep(0.5)

    if rc == 0:
        # Off complete — drop the SIGKILL safety LaunchDaemon so it cannot linger
        # as durable root state after Stay Awake is Off.
        subprocess.call([LAUNCHCTL, "bootout", "system/" + SAFETY_LABEL],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            os.remove(SAFETY_PLIST)
        except OSError:
            pass
        shutil.rmtree(SAFETY_DIR, ignore_errors=True)
        log("sleep-safety LaunchDaemon uninstalled after Off restore")
    else:
        # Could not restore: keep the LaunchDaemon installed. With this watchdog
        # gone it restores lid sleep within a minute; the app also escalates.
        log("pmset restore FAILED — leaving sleep-safety LaunchDaemon as backstop")

    for p in (sentinel, prev, pid_file, ready_file):
        try:
            os.remove(p)
        except OSError:
            pass
    log("watchdog done rc=%s" % rc)
    """

    /// Root shell command that restores lid sleep and removes the safety daemon.
    /// Passed inline to the admin prompt, so restoring never depends on being able
    /// to write a script file first.
    static let restoreCommand = """
    /usr/bin/pmset -a disablesleep 0 && { \(SleepSafetyResources.uninstallShell.split(separator: "\n").joined(separator: "; ")); }
    """

    /// Root Turn On script: claims the session, replaces any previous watchdog, sets
    /// `disablesleep 1`, starts the watchdog, and installs the safety LaunchDaemon.
    /// Prints `watchdog_ok` on success. On any watchdog failure it restores
    /// `disablesleep 0` before exiting non-zero — never leaves a bag-awake Mac.
    static func enableScript(
        stateDirectoryPath: String,
        appProcessIdentifier: Int32,
        sessionID: String,
        stagedSafetyScriptPath: String,
        stagedSafetyPlistPath: String
    ) -> String {
        let statePath = singleQuoteEscaped(stateDirectoryPath)
        let sessionPath = statePath + "/session.id"
        let prevPath = statePath + "/disablesleep.prev"
        let watchdogPidPath = statePath + "/watchdog.pid"
        let readyPath = statePath + "/watchdog.ready"
        let watchdogPyPath = statePath + "/" + watchdogFileName
        let safetySrc = singleQuoteEscaped(stagedSafetyScriptPath)
        let plistSrc = singleQuoteEscaped(stagedSafetyPlistPath)
        let session = singleQuoteEscaped(sessionID)

        return """
        #!/bin/bash
        set -euo pipefail
        mkdir -p '\(statePath)'
        rm -f '\(readyPath)'
        # Claim the session BEFORE killing the old watchdog so a late restore skips.
        printf '%s' '\(session)' > '\(sessionPath)'
        chmod 644 '\(sessionPath)'
        printf '0' > '\(prevPath)'
        chmod 644 '\(prevPath)'
        # Kill any prior watchdog (+ process group) BEFORE pmset 1 so a mid-restore
        # pmset 0 cannot race ahead of the new Stay Awake session.
        # The pid file can be stale and the pid recycled: only ever signal a process
        # that is numeric, not pid 1, and still looks like our watchdog.
        if [ -f '\(watchdogPidPath)' ]; then
          OLD=$(tr -d '[:space:]' < '\(watchdogPidPath)' 2>/dev/null || true)
          case "${OLD}" in
            ''|*[!0-9]*|0*|1) OLD="" ;;
          esac
          if [ -n "${OLD}" ]; then
            OLD_ARGS=$(/bin/ps -p "${OLD}" -o args= 2>/dev/null || true)
            case "${OLD_ARGS}" in
              *\(watchdogFileName)*)
                kill -9 -"${OLD}" 2>/dev/null || kill -9 "${OLD}" 2>/dev/null || true
                for _ in 1 2 3 4 5 6 7 8 9 10; do
                  kill -0 "${OLD}" 2>/dev/null || break
                  sleep 0.1
                done
                ;;
            esac
          fi
        fi
        /usr/bin/pmset -a disablesleep 1
        # Background + redirects only — never nohup (breaks under AppleScript admin:
        # "can't detach from console", the child exits and Turn On reports failure).
        /usr/bin/python3 '\(watchdogPyPath)' '\(statePath)' '\(appProcessIdentifier)' '\(session)' \\
          </dev/null >/dev/null 2>&1 &
        WPID=$!
        echo "${WPID}" > '\(watchdogPidPath)'
        chmod 644 '\(watchdogPidPath)'
        disown "${WPID}" 2>/dev/null || true

        finish_ok() {
          # Boot/periodic safety net: if app+watchdog are later SIGKILL'd, restore sleep.
          SAFETY_DIR="/Library/Application Support/MacStayOn"
          mkdir -p "$SAFETY_DIR"
          cp '\(safetySrc)' "$SAFETY_DIR/sleep-safety.sh"
          chmod 755 "$SAFETY_DIR/sleep-safety.sh"
          cp '\(plistSrc)' /Library/LaunchDaemons/com.markdebartolo.MacStayOn.sleep-safety.plist
          chmod 644 /Library/LaunchDaemons/com.markdebartolo.MacStayOn.sleep-safety.plist
          /bin/launchctl bootout system/com.markdebartolo.MacStayOn.sleep-safety 2>/dev/null || true
          /bin/launchctl bootstrap system /Library/LaunchDaemons/com.markdebartolo.MacStayOn.sleep-safety.plist 2>/dev/null \\
            || /bin/launchctl load -w /Library/LaunchDaemons/com.markdebartolo.MacStayOn.sleep-safety.plist 2>/dev/null \\
            || true
          echo "watchdog_ok"
          exit 0
        }

        for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
          if [ -f '\(readyPath)' ] && kill -0 "${WPID}" 2>/dev/null; then
            finish_ok
          fi
          sleep 0.1
        done
        # FATAL: never leave SleepDisabled=1 if the watchdog did not stay up —
        # UI would show Off while the Mac stays awake in a bag.
        kill -9 "${WPID}" 2>/dev/null || true
        /usr/bin/pmset -a disablesleep 0 || true
        # Partial Turn On must not leave the SIGKILL safety daemon either.
        \(SleepSafetyResources.uninstallShell)
        echo "watchdog_failed" >&2
        exit 1
        """
    }

    /// Escapes a value for use inside single quotes in a POSIX shell.
    static func singleQuoteEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "'\\''")
    }
}
