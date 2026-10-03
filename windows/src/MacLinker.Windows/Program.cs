using MacLinker.Core;
using Microsoft.Win32;

namespace MacLinker.Windows;

internal static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
        using var mutex = new Mutex(true, @"Local\MacLinker.SingleInstance", out var firstInstance);
        if (!firstInstance)
        {
            MessageBox.Show("MacLinker is already running. Look for its icon near the clock.", "MacLinker");
            return;
        }
        ApplicationConfiguration.Initialize();
        Application.Run(new TrayContext(startMinimized: args.Contains("--minimized")));
    }
}

/// <summary>Owns everything: the engine, the input hooks, the tray icon and the window.</summary>
internal sealed class TrayContext : ApplicationContext
{
    private readonly UserSettings _settings = UserSettings.Load();
    private readonly MacLinkerApp _app;
    private readonly WindowsCapture _capture;
    private readonly NotifyIcon _tray;
    private readonly MainForm _form;
    private readonly System.Windows.Forms.Timer _clipboardTimer = new() { Interval = 400 };
    private readonly SynchronizationContext _ui = SynchronizationContext.Current ?? new WindowsFormsSynchronizationContext();

    public TrayContext(bool startMinimized)
    {
        var desktop = WindowsInjector.VirtualScreen();
        var clipboard = new WindowsClipboard();
        _app = new MacLinkerApp(new AppOptions
        {
            SwapModifiers = _settings.SwapModifiers,
            InputSharing = _settings.InputSharing,
            ClipboardSharing = _settings.ClipboardSharing,
            FileSharing = _settings.FileSharing,
        }, new WindowsInjector(), (desktop.Width, desktop.Height), clipboard);
        _app.Control.DoubleClickMs = (int)NativeMethods.GetDoubleClickTime();

        _capture = new WindowsCapture(_app.Control, () => _settings.MouseSpeed);
        _form = new MainForm(_app, _settings);

        _tray = new NotifyIcon
        {
            Icon = Icon.ExtractAssociatedIcon(Environment.ProcessPath!) ?? SystemIcons.Application,
            Text = "MacLinker",
            Visible = true,
            ContextMenuStrip = BuildMenu(),
        };
        _tray.DoubleClick += (_, _) => ShowWindow();

        _app.PairingRequested += prompt => _ui.Post(_ => AskPairing(prompt), null);
        _clipboardTimer.Tick += (_, _) => _app.Clipboard?.Poll();
        _clipboardTimer.Start();
        SystemEvents.DisplaySettingsChanged += (_, _) =>
        {
            var d = WindowsInjector.VirtualScreen();
            _app.Control.Screen = (d.Width, d.Height);
        };

        _app.Start();
        _capture.Start();
        if (!startMinimized || _app.Trusted.All().Count == 0) ShowWindow();
        _ = CheckForUpdateAsync();
    }

    private ContextMenuStrip BuildMenu()
    {
        var menu = new ContextMenuStrip();
        menu.Items.Add("Open MacLinker", null, (_, _) => ShowWindow());
        var input = new ToolStripMenuItem("Share keyboard && mouse") { Checked = _settings.InputSharing, CheckOnClick = true };
        input.CheckedChanged += (_, _) => { _settings.InputSharing = input.Checked; _app.Control.Enabled = input.Checked; _settings.Save(); };
        menu.Items.Add(input);
        menu.Items.Add("Switch to Mac now (Ctrl+Alt+Shift+Space)", null, (_, _) => _app.Control.Toggle());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Quit", null, (_, _) => Quit());
        return menu;
    }

    private void ShowWindow()
    {
        _form.Show();
        _form.WindowState = FormWindowState.Normal;
        _form.Activate();
    }

    private void AskPairing(PairingPrompt prompt)
    {
        using var dialog = new PairingForm(prompt.Name, prompt.Code);
        _app.ConfirmPairing(dialog.ShowDialog() == DialogResult.OK);
    }

    private async Task CheckForUpdateAsync()
    {
        if (await UpdateChecker.NewerReleaseAsync() is not { } release) return;
        _tray.BalloonTipTitle = "MacLinker update available";
        _tray.BalloonTipText = $"{release.Tag} is out. Click to open the download page.";
        _tray.BalloonTipClicked += (_, _) => System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(release.Url) { UseShellExecute = true });
        _tray.ShowBalloonTip(10000);
    }

    private void Quit()
    {
        _tray.Visible = false;
        _clipboardTimer.Stop();
        _capture.Dispose();           // restores the pointer if a Mac was being controlled
        _app.Dispose();
        _settings.Save();
        Application.Exit();
    }
}
