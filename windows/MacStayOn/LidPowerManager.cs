using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace MacStayOn;

/// <summary>
/// Toggles Windows lid-close action to "Do nothing" (and back) via powercfg,
/// and holds a system execution-state request so the machine stays awake.
/// </summary>
internal sealed class LidPowerManager : IDisposable
{
    private const string SubButtons = "SUB_BUTTONS";
    private const string LidAction = "LIDACTION";

    // 0 = Do nothing, 1 = Sleep, 2 = Hibernate, 3 = Shut down
    private const uint DoNothing = 0;

    private static readonly string StatePath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "MacStayOn",
        "state.json");

    private bool _enabled;
    private uint? _savedAc;
    private uint? _savedDc;
    private bool _disposed;

    public bool IsEnabled => _enabled;
    public string? LastError { get; private set; }

    public LidPowerManager()
    {
        LoadPersistedDesire();
    }

    public void ApplyPersistedIfNeeded()
    {
        if (ReadDesire())
        {
            // Re-apply without the heat warning (already consented earlier).
            if (!TryEnable(out var error))
            {
                LastError = error;
                WriteDesire(false);
            }
        }
    }

    public bool RequestEnableFromUser(IWin32Window? owner)
    {
        if (_enabled)
        {
            LastError = null;
            return true;
        }

        var result = MessageBox.Show(
            owner,
            "With this on, closing the lid will not put your PC to sleep. It can overheat if left running in a confined space.\n\n" +
            "Do not put the PC in a bag, under a blanket, or in another enclosed space while MacStayOn is on.",
            "Keep PC awake with lid closed?",
            MessageBoxButtons.OKCancel,
            MessageBoxIcon.Warning);

        if (result != DialogResult.OK)
        {
            LastError = null;
            WriteDesire(false);
            return false;
        }

        if (!TryEnable(out var error))
        {
            LastError = error;
            WriteDesire(false);
            return false;
        }

        LastError = null;
        WriteDesire(true);
        return true;
    }

    public bool Disable()
    {
        try
        {
            ReleaseExecutionState();
            RestoreLidActions();
            _enabled = false;
            LastError = null;
            WriteDesire(false);
            return true;
        }
        catch (Exception ex)
        {
            LastError = ex.Message;
            return false;
        }
    }

    public void PrepareForExit()
    {
        if (_enabled || _savedAc.HasValue || _savedDc.HasValue)
        {
            Disable();
        }
    }

    public string StatusDetail()
    {
        if (LastError is not null)
        {
            return LastError;
        }

        if (!_enabled)
        {
            return "Normal lid sleep";
        }

        var ac = QueryLidAction(ac: true);
        var dc = QueryLidAction(ac: false);
        return $"Lid AC={Describe(ac)} · DC={Describe(dc)} · stay-awake held";
    }

    private bool TryEnable(out string error)
    {
        error = "";
        try
        {
            _savedAc ??= QueryLidAction(ac: true) ?? DoNothing;
            _savedDc ??= QueryLidAction(ac: false) ?? DoNothing;
            PersistSaved();

            SetLidAction(ac: true, DoNothing);
            SetLidAction(ac: false, DoNothing);
            ActivateScheme();
            HoldExecutionState();

            _enabled = true;
            return true;
        }
        catch (Exception ex)
        {
            error = $"Could not change lid settings: {ex.Message}";
            try { RestoreLidActions(); } catch { /* best effort */ }
            ReleaseExecutionState();
            _enabled = false;
            return false;
        }
    }

    private void RestoreLidActions()
    {
        var ac = _savedAc ?? ReadSaved()?.Ac;
        var dc = _savedDc ?? ReadSaved()?.Dc;
        if (ac.HasValue)
        {
            SetLidAction(ac: true, ac.Value);
        }
        if (dc.HasValue)
        {
            SetLidAction(ac: false, dc.Value);
        }
        if (ac.HasValue || dc.HasValue)
        {
            ActivateScheme();
        }
        _savedAc = null;
        _savedDc = null;
        ClearSavedLid();
    }

    private static string Describe(uint? value) => value switch
    {
        0 => "Do nothing",
        1 => "Sleep",
        2 => "Hibernate",
        3 => "Shut down",
        null => "?",
        _ => value.Value.ToString()
    };

    private static uint? QueryLidAction(bool ac)
    {
        // powercfg /q SCHEME_CURRENT SUB_BUTTONS LIDACTION
        var output = RunPowerCfg("/q", "SCHEME_CURRENT", SubButtons, LidAction);
        // Look for "Current AC Power Setting Index: 0x00000001" or DC line
        var label = ac ? "Current AC Power Setting Index" : "Current DC Power Setting Index";
        var match = Regex.Match(
            output,
            $@"{Regex.Escape(label)}:\s*0x([0-9a-fA-F]+)",
            RegexOptions.IgnoreCase);
        if (!match.Success)
        {
            return null;
        }
        return Convert.ToUInt32(match.Groups[1].Value, 16);
    }

    private static void SetLidAction(bool ac, uint value)
    {
        var flag = ac ? "/setacvalueindex" : "/setdcvalueindex";
        RunPowerCfg(flag, "SCHEME_CURRENT", SubButtons, LidAction, value.ToString());
    }

    private static void ActivateScheme()
    {
        RunPowerCfg("/setactive", "SCHEME_CURRENT");
    }

    private static string RunPowerCfg(params string[] args)
    {
        var psi = new ProcessStartInfo
        {
            FileName = "powercfg.exe",
            Arguments = string.Join(' ', args),
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
        };
        using var proc = Process.Start(psi)
            ?? throw new InvalidOperationException("Failed to start powercfg.");
        var stdout = proc.StandardOutput.ReadToEnd();
        var stderr = proc.StandardError.ReadToEnd();
        proc.WaitForExit();
        if (proc.ExitCode != 0)
        {
            throw new InvalidOperationException(
                string.IsNullOrWhiteSpace(stderr) ? $"powercfg exited {proc.ExitCode}" : stderr.Trim());
        }
        return stdout;
    }

    // --- execution state (idle sleep belt-and-suspenders) ---

    [DllImport("kernel32.dll")]
    private static extern uint SetThreadExecutionState(uint esFlags);

    private const uint EsContinuous = 0x80000000;
    private const uint EsSystemRequired = 0x00000001;
    private const uint EsAwayModeRequired = 0x00000040;

    private void HoldExecutionState()
    {
        SetThreadExecutionState(EsContinuous | EsSystemRequired | EsAwayModeRequired);
    }

    private void ReleaseExecutionState()
    {
        SetThreadExecutionState(EsContinuous);
    }

    // --- persistence ---

    private sealed class PersistedState
    {
        public bool DesireEnabled { get; set; }
        public uint? Ac { get; set; }
        public uint? Dc { get; set; }
    }

    private void LoadPersistedDesire()
    {
        // no-op; ApplyPersistedIfNeeded reads desire
    }

    private static bool ReadDesire() => ReadSaved()?.DesireEnabled == true;

    private void WriteDesire(bool enabled)
    {
        var state = ReadSaved() ?? new PersistedState();
        state.DesireEnabled = enabled;
        if (!enabled)
        {
            state.Ac = null;
            state.Dc = null;
        }
        WriteSaved(state);
    }

    private void PersistSaved()
    {
        var state = ReadSaved() ?? new PersistedState();
        state.DesireEnabled = true;
        state.Ac = _savedAc;
        state.Dc = _savedDc;
        WriteSaved(state);
    }

    private void ClearSavedLid()
    {
        var state = ReadSaved() ?? new PersistedState();
        state.Ac = null;
        state.Dc = null;
        WriteSaved(state);
    }

    private static PersistedState? ReadSaved()
    {
        try
        {
            if (!File.Exists(StatePath))
            {
                return null;
            }
            return JsonSerializer.Deserialize<PersistedState>(File.ReadAllText(StatePath));
        }
        catch
        {
            return null;
        }
    }

    private static void WriteSaved(PersistedState state)
    {
        var dir = Path.GetDirectoryName(StatePath)!;
        Directory.CreateDirectory(dir);
        File.WriteAllText(StatePath, JsonSerializer.Serialize(state, new JsonSerializerOptions { WriteIndented = true }));
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
        PrepareForExit();
    }
}
