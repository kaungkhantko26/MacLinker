using MacLinker.Core;

namespace MacLinker.Windows;

/// <summary>The main window: your Macs, where each one sits, quick actions and settings.</summary>
internal sealed class MainForm : Form
{
    private readonly MacLinkerApp _app;
    private readonly UserSettings _settings;
    private readonly ListView _devices = new() { View = View.Details, FullRowSelect = true, HideSelection = false, MultiSelect = false, Dock = DockStyle.Fill };
    private readonly ComboBox _position = new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = 110 };
    private readonly TextBox _address = new() { Width = 220, PlaceholderText = "192.168.1.6 or mac-mini.local[:port]" };
    private readonly Label _status = new() { AutoSize = true };
    private readonly TextBox _log = new() { Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, Dock = DockStyle.Fill, Font = new Font("Consolas", 9) };
    private readonly Button _send = new() { Text = "Send File…", AutoSize = true, Enabled = false };
    private readonly Button _connect = new() { Text = "Connect", AutoSize = true, Enabled = false };
    private readonly Button _forget = new() { Text = "Unpair", AutoSize = true, Enabled = false };
    private bool _updating;

    public MainForm(MacLinkerApp app, UserSettings settings)
    {
        _app = app;
        _settings = settings;
        Text = "MacLinker";
        Icon = Icon.ExtractAssociatedIcon(Environment.ProcessPath!);
        ClientSize = new Size(820, 600);
        MinimumSize = new Size(760, 520);
        StartPosition = FormStartPosition.CenterScreen;
        Font = new Font("Segoe UI", 10);

        _devices.Columns.Add("Name", 220);
        _devices.Columns.Add("Status", 130);
        _devices.Columns.Add("Latency", 80);
        _devices.Columns.Add("Position", 90);
        _devices.Columns.Add("Version", 80);
        _devices.SelectedIndexChanged += (_, _) => OnSelection();
        _position.Items.AddRange(new object[] { "Not set", "Left", "Right", "Top", "Bottom" });
        _position.SelectedIndexChanged += (_, _) => OnPositionPicked();

        var root = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 5, Padding = new Padding(14) };
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 55));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 45));

        root.Controls.Add(new Label { Text = "Your Macs", Font = new Font("Segoe UI", 16, FontStyle.Bold), AutoSize = true, Margin = new Padding(0, 0, 0, 8) });
        root.Controls.Add(_devices);

        var actions = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Fill, Margin = new Padding(0, 8, 0, 4) };
        _connect.Click += async (_, _) => await ConnectSelectedAsync();
        _send.Click += async (_, _) => await SendFileAsync();
        _forget.Click += async (_, _) => await ForgetSelectedAsync();
        var add = new Button { Text = "Connect", AutoSize = true };
        add.Click += async (_, _) => await AddByAddressAsync();
        actions.Controls.AddRange(new Control[]
        {
            _connect, _send, _forget, new Label { Text = "   This Mac sits:", AutoSize = true, Margin = new Padding(8, 8, 2, 0) }, _position,
            new Label { Text = "   Add by address:", AutoSize = true, Margin = new Padding(8, 8, 2, 0) }, _address, add,
        });
        root.Controls.Add(actions);

        var options = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Fill, Margin = new Padding(0, 4, 0, 4) };
        options.Controls.Add(Check("Share keyboard & mouse", _settings.InputSharing, v => { _settings.InputSharing = v; _app.Control.Enabled = v; }));
        options.Controls.Add(Check("Share clipboard", _settings.ClipboardSharing, v => { _settings.ClipboardSharing = v; _app.Options.ClipboardSharing = v; }));
        options.Controls.Add(Check("Accept files", _settings.FileSharing, v => { _settings.FileSharing = v; _app.Options.FileSharing = v; }));
        options.Controls.Add(Check("Ctrl ↔ Command, Alt ↔ Option", _settings.SwapModifiers, v => { _settings.SwapModifiers = v; MessageBox.Show(this, "Restart MacLinker for this to take effect.", "MacLinker"); }));
        options.Controls.Add(Check("Start with Windows", UserSettings.StartsWithWindows, v => UserSettings.StartsWithWindows = v));
        root.Controls.Add(options);

        var bottom = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 2 };
        bottom.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        bottom.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        bottom.Controls.Add(_status);
        bottom.Controls.Add(_log);
        root.Controls.Add(bottom);
        Controls.Add(root);

        _app.Changed += () => BeginInvokeSafe(RefreshDevices);
        _app.Log += m => BeginInvokeSafe(() => _log.AppendText($"{DateTime.Now:HH:mm:ss}  {m}{Environment.NewLine}"));
        _app.Control.StateChanged += _ => BeginInvokeSafe(RefreshStatus);
        FormClosing += (_, e) => { _settings.Save(); if (e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; Hide(); } };
        Load += (_, _) => { RefreshDevices(); RefreshStatus(); };
    }

    private CheckBox Check(string text, bool value, Action<bool> changed)
    {
        var c = new CheckBox { Text = text, Checked = value, AutoSize = true, Margin = new Padding(0, 0, 18, 0) };
        c.CheckedChanged += (_, _) => { changed(c.Checked); _settings.Save(); };
        return c;
    }

    private void BeginInvokeSafe(Action a)
    {
        if (IsDisposed || !IsHandleCreated) return;
        try { BeginInvoke(a); } catch (InvalidOperationException) { }
    }

    private DeviceStatus? Selected => _devices.SelectedItems.Count == 1 ? _devices.SelectedItems[0].Tag as DeviceStatus : null;

    private void RefreshDevices()
    {
        var selectedId = Selected?.Id;
        _devices.BeginUpdate();
        _devices.Items.Clear();
        foreach (var d in _app.Devices())
        {
            var status = d.Connected ? "Connected" : d.Pairing ? "Pairing…" : d.Nearby ? (d.Trusted ? "Nearby" : "Nearby · not paired") : "Offline";
            var item = new ListViewItem(new[]
            {
                d.Name, status, d.LatencyMs is { } ms ? $"{ms:F0} ms" : "", d.Position is { } p ? char.ToUpper(p[0]) + p[1..] : "—", d.Version,
            }) { Tag = d, Selected = d.Id == selectedId };
            _devices.Items.Add(item);
        }
        _devices.EndUpdate();
        OnSelection();
        RefreshStatus();
    }

    private void RefreshStatus()
    {
        var connected = _app.Devices().Count(d => d.Connected);
        var control = _app.Control.State.Kind switch
        {
            ControlKind.Controlling => "  ·  Controlling a Mac (Ctrl+Alt+Shift+Space to come back)",
            ControlKind.Controlled => "  ·  A Mac is controlling this PC",
            _ => "",
        };
        _status.Text = (connected == 0 ? "No Macs connected" : $"{connected} Mac{(connected > 1 ? "s" : "")} connected") + control
                       + "  ·  Hotkey: Ctrl+Alt+Shift+Space switches to your Mac";
    }

    private void OnSelection()
    {
        var d = Selected;
        _connect.Enabled = d is { Connected: false, Nearby: true } || d is { Connected: false, Trusted: true, Host: not null };
        _connect.Text = d is { Trusted: false } ? "Pair" : "Connect";
        _send.Enabled = d is { Connected: true };
        _forget.Enabled = d is { Trusted: true };
        _updating = true;
        _position.SelectedIndex = d?.Position is { } p ? Array.FindIndex(new[] { "left", "right", "top", "bottom" }, x => x == p) + 1 : 0;
        _position.Enabled = d is { Trusted: true };
        _updating = false;
    }

    private void OnPositionPicked()
    {
        if (_updating || Selected is not { } d) return;
        var edge = _position.SelectedIndex switch { 1 => Edge.Left, 2 => Edge.Right, 3 => Edge.Top, 4 => Edge.Bottom, _ => (Edge?)null };
        _app.SetPosition(d.Id, edge);
    }

    private async Task ConnectSelectedAsync()
    {
        if (Selected is not { Host: { } host } d) return;
        var port = _app.Trusted.Get(d.Id)?.LastPort ?? 52845;
        await _app.ConnectAsync(host, port, d.Trusted ? d.Id : null);
    }

    private async Task AddByAddressAsync()
    {
        var text = _address.Text.Trim();
        if (text.Length == 0) return;
        var (host, port) = ParseAddress(text);
        _app.Say(await _app.ConnectAsync(host, port));
        _address.Clear();
    }

    internal static (string Host, int Port) ParseAddress(string text)
    {
        var i = text.LastIndexOf(':');
        return i > 0 && text.IndexOf(':') == i && int.TryParse(text[(i + 1)..], out var p) && p is > 0 and < 65536 ? (text[..i], p) : (text, 52845);
    }

    private async Task SendFileAsync()
    {
        if (Selected is not { } d) return;
        using var dialog = new OpenFileDialog { Multiselect = true, Title = $"Send to {d.Name}" };
        if (dialog.ShowDialog(this) != DialogResult.OK) return;
        foreach (var path in dialog.FileNames) _app.Say($"{Path.GetFileName(path)}: {await _app.SendFileAsync(d.Id, path)}");
    }

    private async Task ForgetSelectedAsync()
    {
        if (Selected is not { } d) return;
        if (MessageBox.Show(this, $"Unpair “{d.Name}”? You can pair again later.", "MacLinker", MessageBoxButtons.YesNo) != DialogResult.Yes) return;
        await _app.ForgetAsync(d.Id);
    }
}
