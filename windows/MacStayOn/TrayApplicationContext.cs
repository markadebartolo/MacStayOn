namespace MacStayOn;

internal sealed class TrayApplicationContext : ApplicationContext
{
    private readonly NotifyIcon _tray;
    private readonly LidPowerManager _manager;
    private readonly ToolStripMenuItem _statusItem;
    private readonly ToolStripMenuItem _detailItem;
    private readonly ToolStripMenuItem _toggleItem;

    public TrayApplicationContext()
    {
        _manager = new LidPowerManager();

        _statusItem = new ToolStripMenuItem("Status: …") { Enabled = false };
        _detailItem = new ToolStripMenuItem("…") { Enabled = false };
        _toggleItem = new ToolStripMenuItem("Turn On (lid closed stays awake)", null, OnToggle);

        var quitItem = new ToolStripMenuItem("Quit MacStayOn", null, OnQuit);

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
            Icon = SystemIcons.Application,
            Visible = true,
            Text = "MacStayOn Off",
            ContextMenuStrip = menu,
        };
        _tray.MouseUp += (_, e) =>
        {
            if (e.Button == MouseButtons.Left)
            {
                // Show context menu on left click too.
                typeof(NotifyIcon)
                    .GetMethod("ShowContextMenu", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)
                    ?.Invoke(_tray, null);
            }
        };

        Application.ApplicationExit += (_, _) => Cleanup();

        _manager.ApplyPersistedIfNeeded();
        RefreshMenu();
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
        _tray.Text = on ? "MacStayOn On" : "MacStayOn Off";
        _tray.Icon = on ? SystemIcons.Shield : SystemIcons.Application;
    }

    private void OnToggle(object? sender, EventArgs e)
    {
        if (_manager.IsEnabled)
        {
            _manager.Disable();
        }
        else
        {
            _manager.RequestEnableFromUser(null);
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
    }
}
