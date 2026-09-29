namespace PCStayOn;

internal sealed class TrayApplicationContext : ApplicationContext
{
    private readonly NotifyIcon _tray;
    private readonly LidPowerManager _manager;
    private readonly ToolStripMenuItem _statusItem;
    private readonly ToolStripMenuItem _detailItem;
    private readonly ToolStripMenuItem _toggleItem;
    private Icon _iconOff;
    private Icon _iconOn;

    public TrayApplicationContext()
    {
        _manager = new LidPowerManager();
        _iconOff = AppIcons.Create(enabled: false);
        _iconOn = AppIcons.Create(enabled: true);

        _statusItem = new ToolStripMenuItem("Status: …") { Enabled = false };
        _detailItem = new ToolStripMenuItem("…") { Enabled = false };
        _toggleItem = new ToolStripMenuItem("Turn On (lid closed stays awake)", null, OnToggle);

        var quitItem = new ToolStripMenuItem("Quit PCStayOn", null, OnQuit);

        var menu = new ContextMenuStrip();
        menu.Items.Add(_statusItem);
        menu.Items.Add(_detailItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(_toggleItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(quitItem);
        menu.Opening += (_, _) => RefreshMenu();

        _tray = new NotifyIcon
        {
            Icon = _iconOff,
            Visible = true,
            Text = "PCStayOn Off",
            ContextMenuStrip = menu,
        };
        _tray.MouseUp += (_, e) =>
        {
            if (e.Button == MouseButtons.Left)
            {
                typeof(NotifyIcon)
                    .GetMethod("ShowContextMenu", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)
                    ?.Invoke(_tray, null);
            }
        };

        Application.ApplicationExit += (_, _) => Cleanup();

        _manager.ApplyPersistedIfNeeded();
        RefreshMenu();

        _tray.BalloonTipTitle = "PCStayOn";
        _tray.BalloonTipText = "Running in the system tray. Right-click the sun/moon icon.";
        _tray.ShowBalloonTip(3000);
    }

    private void RefreshMenu()
    {
        var on = _manager.IsEnabled;
        _statusItem.Text = on
            ? "Status: Lid closed stays awake"
            : "Status: Normal lid sleep";
        _detailItem.Text = _manager.StatusDetail();
        _toggleItem.Text = on
            ? "Turn Off (resume normal lid sleep)"
            : "Turn On (lid closed stays awake)";
        _tray.Text = on ? "PCStayOn On" : "PCStayOn Off";
        _tray.Icon = on ? _iconOn : _iconOff;
    }

    private void OnToggle(object? sender, EventArgs e)
    {
        if (_manager.IsEnabled)
        {
            _manager.Disable();
        }
        else
        {
            var ok = _manager.RequestEnableFromUser(null);
            if (ok)
            {
                _tray.BalloonTipTitle = "PCStayOn On";
                _tray.BalloonTipText =
                    "Lid close should not sleep the PC. The screen still goes dark when closed — that is normal.";
                _tray.ShowBalloonTip(5000);
            }
            else if (_manager.LastError is not null)
            {
                MessageBox.Show(_manager.LastError, "PCStayOn", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }
        RefreshMenu();
    }

    private void OnQuit(object? sender, EventArgs e)
    {
        Cleanup();
        ExitThread();
    }

    private void Cleanup()
    {
        _manager.PrepareForExit();
        _tray.Visible = false;
        _tray.Dispose();
        _manager.Dispose();
        _iconOn.Dispose();
        _iconOff.Dispose();
    }
}
