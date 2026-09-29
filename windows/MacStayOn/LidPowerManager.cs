using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace MacStayOn;

/// <summary>
/// Keeps a Windows laptop awake with the lid closed by:
/// 1. Setting lid-close action to Do nothing (AC + DC)
/// 2. Setting sleep/hibernate idle timeouts to Never while enabled
/// 3. Holding PowerRequest + SetThreadExecutionState (refreshed on a timer)
///
/// Note: the built-in screen goes dark when the lid is physically closed —
/// that is normal. Success means the PC keeps running (fans/CPU/network).
/// </summary>
internal sealed class LidPowerManager : IDisposable
{
    // Prefer GUIDs — aliases are flaky on some OEM images.
    private const string SubButtons = "4f971e89-eebd-4455-a8de-9e59040e7347"; // SUB_BUTTONS
    private const string LidAction = "5ca83367-6e45-459f-a27b-476b1d01c936"; // LIDACTION
    private const string SubSleep = "238c9fa8-0aad-41ed-83f4-97be242c8f20"; // SUB_SLEEP
    private const string StandbyIdle = "29f6c1db-86da-48c5-9fdb-f2b67b1f44da"; // STANDBYIDLE
    private const string HibernateIdle = "9d7815a6-7ee4-497e-8888-515a05f02364"; // HIBERNATEIDLE

    private const uint DoNothing = 0;

    private static readonly string StatePath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "MacStayOn",
        "state.json");

    private bool _enabled;
    private uint? _savedLidAc;
    private uint? _savedLidDc;
    private uint? _savedStandbyAc;
    private uint? _savedStandbyDc;
    private uint? _savedHibernateAc;
    private uint? _savedHibernateDc;
    private string? _schemeGuid;
    private IntPtr _powerRequest = IntPtr.Zero;
    private System.Windows.Forms.Timer? _keepAliveTimer;
    private bool _disposed;

    public bool IsEnabled => _enabled;
    public string? LastError { get; private set; }

    public void ApplyPersistedIfNeeded()
    {
        if (ReadDesire())
        {
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
            "With this on, closing the lid should not put your PC to sleep.\n\n" +
            "The built-in screen will go dark when the lid is closed — that is normal. " +
            "The PC should keep running (fans/CPU/agents).\n\n" +
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
            StopKeepAlive();
            ReleasePowerRequest();
            ReleaseExecutionState();
            RestoreAll();
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
        if (_enabled || _savedLidAc.HasValue || _savedLidDc.HasValue)
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

        var ac = QueryIndex(SubButtons, LidAction, ac: true);
        var dc = QueryIndex(SubButtons, LidAction, ac: false);
        var modern = DetectsModernStandby() ? " · Modern Standby PC" : "";
        return $"Lid AC={DescribeLid(ac)} · DC={DescribeLid(dc)}{modern}";
    }

    private bool TryEnable(out string error)
    {
        error = "";
        try
        {
            _schemeGuid = GetActiveSchemeGuid();

            _savedLidAc ??= QueryIndex(SubButtons, LidAction, ac: true) ?? DoNothing;
            _savedLidDc ??= QueryIndex(SubButtons, LidAction, ac: false) ?? DoNothing;
            _savedStandbyAc ??= QueryIndex(SubSleep, StandbyIdle, ac: true);
            _savedStandbyDc ??= QueryIndex(SubSleep, StandbyIdle, ac: false);
            _savedHibernateAc ??= QueryIndex(SubSleep, HibernateIdle, ac: true);
            _savedHibernateDc ??= QueryIndex(SubSleep, HibernateIdle, ac: false);
            PersistSaved();

            SetIndex(SubButtons, LidAction, ac: true, DoNothing);
            SetIndex(SubButtons, LidAction, ac: false, DoNothing);
            SetIndex(SubSleep, StandbyIdle, ac: true, 0);
            SetIndex(SubSleep, StandbyIdle, ac: false, 0);
            SetIndex(SubSleep, HibernateIdle, ac: true, 0);
            SetIndex(SubSleep, HibernateIdle, ac: false, 0);
            ActivateScheme();

            // Confirm lid actually flipped.
            var acNow = QueryIndex(SubButtons, LidAction, ac: true);
            var dcNow = QueryIndex(SubButtons, LidAction, ac: false);
            if (acNow != DoNothing || dcNow != DoNothing)
            {
                throw new InvalidOperationException(
                    $"Lid action did not stick (AC={acNow}, DC={dcNow}). Try running PowerShell as Administrator.");
            }

            CreatePowerRequest();
            HoldExecutionState();
            StartKeepAlive();

            _enabled = true;
            return true;
        }
        catch (Exception ex)
        {
            error = $"Could not enable stay-awake: {ex.Message}";
            try { RestoreAll(); } catch { /* best effort */ }
            StopKeepAlive();
            ReleasePowerRequest();
            ReleaseExecutionState();
            _enabled = false;
            return false;
        }
    }

    private void RestoreAll()
    {
        var s = ReadSaved();
        RestoreOne(SubButtons, LidAction, true, _savedLidAc ?? s?.LidAc);
        RestoreOne(SubButtons, LidAction, false, _savedLidDc ?? s?.LidDc);
        RestoreOne(SubSleep, StandbyIdle, true, _savedStandbyAc ?? s?.StandbyAc);
        RestoreOne(SubSleep, StandbyIdle, false, _savedStandbyDc ?? s?.StandbyDc);
        RestoreOne(SubSleep, HibernateIdle, true, _savedHibernateAc ?? s?.HibernateAc);
        RestoreOne(SubSleep, HibernateIdle, false, _savedHibernateDc ?? s?.HibernateDc);
        ActivateScheme();

        _savedLidAc = _savedLidDc = null;
        _savedStandbyAc = _savedStandbyDc = null;
        _savedHibernateAc = _savedHibernateDc = null;
        ClearSavedPower();
    }

    private void RestoreOne(string subgroup, string setting, bool ac, uint? value)
    {
        if (value.HasValue)
        {
            SetIndex(subgroup, setting, ac, value.Value);
        }
    }

    private static string DescribeLid(uint? value) => value switch
    {
        0 => "Do nothing",
        1 => "Sleep",
        2 => "Hibernate",
        3 => "Shut down",
        null => "?",
        _ => value.Value.ToString()
    };

    private string Scheme => _schemeGuid ?? "SCHEME_CURRENT";

    private static string GetActiveSchemeGuid()
    {
        var output = RunPowerCfg("/getactivescheme");
        var match = Regex.Match(
            output,
            @"GUID:\s*([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})",
            RegexOptions.IgnoreCase);
        if (!match.Success)
        {
            return "SCHEME_CURRENT";
        }
        return match.Groups[1].Value;
    }

    private uint? QueryIndex(string subgroup, string setting, bool ac)
    {
        var output = RunPowerCfg("/q", Scheme, subgroup, setting);
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

    private void SetIndex(string subgroup, string setting, bool ac, uint value)
    {
        var flag = ac ? "/setacvalueindex" : "/setdcvalueindex";
        RunPowerCfg(flag, Scheme, subgroup, setting, value.ToString());
    }

    private void ActivateScheme()
    {
        RunPowerCfg("/setactive", Scheme);
    }

    private static bool DetectsModernStandby()
    {
        try
        {
            var output = RunPowerCfg("/a");
            return output.Contains("Standby (S0 Low Power Idle)", StringComparison.OrdinalIgnoreCase)
                && !output.Contains("Standby (S3)", StringComparison.OrdinalIgnoreCase);
        }
        catch
        {
            return false;
        }
    }

    private static string RunPowerCfg(params string[] args)
    {
        var psi = new ProcessStartInfo
        {
            FileName = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.System),
                "powercfg.exe"),
            ArgumentList = { },
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
        };
        foreach (var a in args)
        {
            psi.ArgumentList.Add(a);
        }

        using var proc = Process.Start(psi)
            ?? throw new InvalidOperationException("Failed to start powercfg.");
        var stdout = proc.StandardOutput.ReadToEnd();
        var stderr = proc.StandardError.ReadToEnd();
        proc.WaitUntilExit();
        if (proc.ExitCode != 0)
        {
            throw new InvalidOperationException(
                string.IsNullOrWhiteSpace(stderr) ? $"powercfg exited {proc.ExitCode}" : stderr.Trim());
        }
        return stdout;
    }

    // --- PowerRequest + execution state ---

    private enum PowerRequestType
    {
        DisplayRequired = 0,
        SystemRequired = 1,
        AwayModeRequired = 2,
        ExecutionRequired = 3,
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct ReasonContext
    {
        public uint Version;
        public uint Flags;
        public IntPtr SimpleReasonString;
    }

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr PowerCreateRequest(ref ReasonContext context);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool PowerSetRequest(IntPtr powerRequest, PowerRequestType requestType);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool PowerClearRequest(IntPtr powerRequest, PowerRequestType requestType);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    [DllImport("kernel32.dll")]
    private static extern uint SetThreadExecutionState(uint esFlags);

    private const uint EsContinuous = 0x80000000;
    private const uint EsSystemRequired = 0x00000001;
    private const uint EsDisplayRequired = 0x00000002;
    private const uint EsAwayModeRequired = 0x00000040;

    private void CreatePowerRequest()
    {
        ReleasePowerRequest();
        var reason = Marshal.StringToHGlobalUni("MacStayOn: keep system awake with lid closed");
        try
        {
            var ctx = new ReasonContext
            {
                Version = 0, // POWER_REQUEST_CONTEXT_VERSION
                Flags = 1,   // POWER_REQUEST_CONTEXT_SIMPLE_STRING
                SimpleReasonString = reason,
            };
            _powerRequest = PowerCreateRequest(ref ctx);
            if (_powerRequest == IntPtr.Zero)
            {
                throw new InvalidOperationException($"PowerCreateRequest failed ({Marshal.GetLastWin32Error()}).");
            }

            PowerSetRequest(_powerRequest, PowerRequestType.SystemRequired);
            PowerSetRequest(_powerRequest, PowerRequestType.AwayModeRequired);
            PowerSetRequest(_powerRequest, PowerRequestType.ExecutionRequired);
        }
        finally
        {
            Marshal.FreeHGlobal(reason);
        }
    }

    private void ReleasePowerRequest()
    {
        if (_powerRequest == IntPtr.Zero)
        {
            return;
        }

        try
        {
            PowerClearRequest(_powerRequest, PowerRequestType.SystemRequired);
            PowerClearRequest(_powerRequest, PowerRequestType.AwayModeRequired);
            PowerClearRequest(_powerRequest, PowerRequestType.ExecutionRequired);
        }
        catch { /* ignore */ }

        CloseHandle(_powerRequest);
        _powerRequest = IntPtr.Zero;
    }

    private void HoldExecutionState()
    {
        // Away-mode helps media/"closed lid" scenarios; system-required blocks idle sleep.
        SetThreadExecutionState(EsContinuous | EsSystemRequired | EsAwayModeRequired);
    }

    private void ReleaseExecutionState()
    {
        SetThreadExecutionState(EsContinuous);
    }

    private void StartKeepAlive()
    {
        StopKeepAlive();
        _keepAliveTimer = new System.Windows.Forms.Timer { Interval = 30_000 };
        _keepAliveTimer.Tick += (_, _) => HoldExecutionState();
        _keepAliveTimer.Start();
    }

    private void StopKeepAlive()
    {
        if (_keepAliveTimer is null)
        {
            return;
        }
        _keepAliveTimer.Stop();
        _keepAliveTimer.Dispose();
        _keepAliveTimer = null;
    }

    // --- persistence ---

    private sealed class PersistedState
    {
        public bool DesireEnabled { get; set; }
        public uint? LidAc { get; set; }
        public uint? LidDc { get; set; }
        public uint? StandbyAc { get; set; }
        public uint? StandbyDc { get; set; }
        public uint? HibernateAc { get; set; }
        public uint? HibernateDc { get; set; }
    }

    private static bool ReadDesire() => ReadSaved()?.DesireEnabled == true;

    private void WriteDesire(bool enabled)
    {
        var state = ReadSaved() ?? new PersistedState();
        state.DesireEnabled = enabled;
        if (!enabled)
        {
            ClearPowerFields(state);
        }
        WriteSaved(state);
    }

    private void PersistSaved()
    {
        var state = ReadSaved() ?? new PersistedState();
        state.DesireEnabled = true;
        state.LidAc = _savedLidAc;
        state.LidDc = _savedLidDc;
        state.StandbyAc = _savedStandbyAc;
        state.StandbyDc = _savedStandbyDc;
        state.HibernateAc = _savedHibernateAc;
        state.HibernateDc = _savedHibernateDc;
        WriteSaved(state);
    }

    private void ClearSavedPower()
    {
        var state = ReadSaved() ?? new PersistedState();
        ClearPowerFields(state);
        WriteSaved(state);
    }

    private static void ClearPowerFields(PersistedState state)
    {
        state.LidAc = state.LidDc = null;
        state.StandbyAc = state.StandbyDc = null;
        state.HibernateAc = state.HibernateDc = null;
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
        Directory.CreateDirectory(Path.GetDirectoryName(StatePath)!);
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
