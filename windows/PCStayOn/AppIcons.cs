namespace PCStayOn;

internal static class AppIcons
{
    public static Icon Create(bool enabled)
    {
        // 32x32 tray glyph: sun when on, moon when off.
        var bmp = new Bitmap(32, 32);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            g.Clear(Color.Transparent);

            if (enabled)
            {
                using var fill = new SolidBrush(Color.FromArgb(255, 240, 180, 40));
                using var rim = new Pen(Color.FromArgb(255, 180, 110, 0), 2);
                g.FillEllipse(fill, 6, 6, 20, 20);
                g.DrawEllipse(rim, 6, 6, 20, 20);
                using var ray = new Pen(Color.FromArgb(255, 240, 180, 40), 2);
                for (var i = 0; i < 8; i++)
                {
                    var a = i * Math.PI / 4;
                    var x1 = 16 + Math.Cos(a) * 11;
                    var y1 = 16 + Math.Sin(a) * 11;
                    var x2 = 16 + Math.Cos(a) * 14;
                    var y2 = 16 + Math.Sin(a) * 14;
                    g.DrawLine(ray, (float)x1, (float)y1, (float)x2, (float)y2);
                }
            }
            else
            {
                using var fill = new SolidBrush(Color.FromArgb(255, 90, 110, 160));
                g.FillEllipse(fill, 8, 6, 18, 18);
                using var cut = new SolidBrush(Color.FromArgb(0, 0, 0, 0));
                // Punch a crescent by clearing an offset circle.
                g.CompositingMode = System.Drawing.Drawing2D.CompositingMode.SourceCopy;
                g.FillEllipse(Brushes.Transparent, 14, 4, 18, 18);
                g.CompositingMode = System.Drawing.Drawing2D.CompositingMode.SourceOver;
            }
        }

        // Keep bitmap alive via Icon ownership.
        var hIcon = bmp.GetHicon();
        var icon = Icon.FromHandle(hIcon);
        // Clone so we can free the temporary handle/bitmap safely.
        var clone = (Icon)icon.Clone();
        DestroyIcon(hIcon);
        bmp.Dispose();
        return clone;
    }

    [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Auto)]
    private static extern bool DestroyIcon(IntPtr handle);
}
