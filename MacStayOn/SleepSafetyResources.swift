import Foundation

/// Files installed into `/Library` on first successful Turn On (admin) so a
/// LaunchDaemon can restore lid sleep after SIGKILL of app + watchdog.
enum SleepSafetyResources {
    static let scriptName = "sleep-safety.sh"
    static let plistName = "sleep-safety.plist"

    static let script = """
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
