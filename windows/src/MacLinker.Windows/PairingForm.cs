namespace MacLinker.Windows;

/// <summary>Shows the pairing code. Both people must see the same six digits before confirming.</summary>
internal sealed class PairingForm : Form
{
    public PairingForm(string deviceName, string code)
    {
        Text = "Pair with a Mac";
        FormBorderStyle = FormBorderStyle.FixedDialog;
        StartPosition = FormStartPosition.CenterScreen;
        MaximizeBox = MinimizeBox = false;
        TopMost = true;
        ClientSize = new Size(420, 280);
        Font = new Font("Segoe UI", 10);

        Controls.Add(new Label { Text = $"Pair with “{deviceName}”", Font = new Font("Segoe UI", 14, FontStyle.Bold), AutoSize = false, TextAlign = ContentAlignment.MiddleCenter, Bounds = new Rectangle(10, 14, 400, 34) });
        Controls.Add(new Label { Text = "Check that this code is identical on both computers, then confirm on both.", AutoSize = false, TextAlign = ContentAlignment.MiddleCenter, Bounds = new Rectangle(20, 52, 380, 44) });
        Controls.Add(new Label { Text = code.Length == 6 ? $"{code[..3]} {code[3..]}" : code, Font = new Font("Consolas", 36, FontStyle.Bold), AutoSize = false, TextAlign = ContentAlignment.MiddleCenter, Bounds = new Rectangle(10, 100, 400, 70) });
        var ok = new Button { Text = "Codes Match", DialogResult = DialogResult.OK, Bounds = new Rectangle(210, 190, 190, 36) };
        var cancel = new Button { Text = "Cancel", DialogResult = DialogResult.Cancel, Bounds = new Rectangle(20, 190, 170, 36) };
        Controls.AddRange(new Control[] { ok, cancel });
        Controls.Add(new Label { Text = "If the codes differ, press Cancel: someone may be intercepting the connection.", ForeColor = SystemColors.GrayText, AutoSize = false, TextAlign = ContentAlignment.MiddleCenter, Bounds = new Rectangle(20, 236, 380, 36) });
        AcceptButton = ok;
        CancelButton = cancel;
    }
}
