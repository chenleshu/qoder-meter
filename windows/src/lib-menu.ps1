# Native WinForms popup styling. No network, settings writes or bitmap assets.
# Keep ToolStripMenuItem semantics for keyboard navigation and accessibility.
if (-not ('QoderMeter.MenuRenderer' -as [type])) {
 Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;
namespace QoderMeter {
 public static class MenuDisplay {
  [DllImport("user32.dll")] private static extern IntPtr MonitorFromPoint(Point point, uint flags);
  [DllImport("shcore.dll")] private static extern int GetDpiForMonitor(IntPtr monitor, int type, out uint x, out uint y);
  public static double ScaleAt(Point point) {
   try {
    uint x, y;
    if (GetDpiForMonitor(MonitorFromPoint(point, 2), 0, out x, out y) == 0 && x > 0) return x / 96.0;
   } catch (DllNotFoundException) { } catch (EntryPointNotFoundException) { }
   return 1;
  }
 }
 public class MenuEntry : ToolStripMenuItem {
  public string Glyph = "";
  public string Detail = "";
  public string Kind = "action";
  public string Tone = "";
  public string LayoutIcon = "";
  public Color Swatch { get; set; }
  public float UiScale = 1;
  public MenuEntry(string text) : base(text) { AutoToolTip = false; }
  // Session titles can contain literal '&'; they are not menu accelerators.
  protected override bool ProcessMnemonic(char charCode) { return false; }
  public override Size GetPreferredSize(Size constrainingSize) {
   int height = Kind == "section" ? 26 : (Kind == "summary" ? 62 : (Detail.Length > 0 ? 48 : 34));
   int textWidth = TextRenderer.MeasureText(Text, Font, Size.Empty, TextFormatFlags.NoPrefix).Width;
   // A bounded label column ellipsizes long session names, never the action area.
   int width = Math.Min((int)(360 * UiScale), Math.Max((int)(294 * UiScale), textWidth + (int)(90 * UiScale)));
   return new Size(width, (int)Math.Ceiling(height * UiScale));
  }
 }
 public class MeterMenu : ContextMenuStrip {
  private Font ownedFont;
  public MeterMenu(float scale) {
   ownedFont = new Font("Microsoft YaHei UI", 12F * scale, FontStyle.Regular, GraphicsUnit.Pixel);
   Font = ownedFont;
   ShowImageMargin = false; ShowCheckMargin = false;
   ShowItemToolTips = true;
   Padding = new Padding(5, 5, 5, 5);
   AccessibleName = "Qoder Meter";
  }
  protected override void Dispose(bool disposing) {
   base.Dispose(disposing);
   if (disposing && ownedFont != null) { ownedFont.Dispose(); ownedFont = null; }
  }
 }
 public class MenuRenderer : ToolStripRenderer {
  public Color Background, Foreground, Muted, Border, Hover, Accent, Danger, Gold;
  public float UiScale = 1;
  private int P(float value) { return (int)Math.Round(value * UiScale); }
  private Color Ink(MenuEntry item) {
   if (!item.Enabled && item.Kind == "action") return Muted;
   if (item.Tone == "red") return Danger;
   if (item.Tone == "gold") return Gold;
   if (item.Tone == "green") return Accent;
   return Foreground;
  }
  private static GraphicsPath Rounded(Rectangle r, int radius) {
   GraphicsPath path = new GraphicsPath(); int d = radius * 2;
   path.AddArc(r.Left, r.Top, d, d, 180, 90); path.AddArc(r.Right-d, r.Top, d, d, 270, 90);
   path.AddArc(r.Right-d, r.Bottom-d, d, d, 0, 90); path.AddArc(r.Left, r.Bottom-d, d, d, 90, 90);
   path.CloseFigure(); return path;
  }
  protected override void OnRenderToolStripBackground(ToolStripRenderEventArgs e) { e.Graphics.Clear(Background); }
  protected override void OnRenderToolStripBorder(ToolStripRenderEventArgs e) {
   using (Pen pen = new Pen(Border)) e.Graphics.DrawRectangle(pen, 0, 0, e.ToolStrip.Width-1, e.ToolStrip.Height-1);
  }
  protected override void OnRenderImageMargin(ToolStripRenderEventArgs e) { }
  protected override void OnRenderItemCheck(ToolStripItemImageRenderEventArgs e) { }
  protected override void OnRenderMenuItemBackground(ToolStripItemRenderEventArgs e) {
   MenuEntry item = e.Item as MenuEntry;
   if (item == null || !item.Enabled || !item.Selected) return;
   e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
   Rectangle r = new Rectangle(P(2), P(1), item.Width-P(4), item.Height-P(2));
   using (GraphicsPath path = Rounded(r, P(6))) using (Brush brush = new SolidBrush(Hover)) e.Graphics.FillPath(brush, path);
  }
  protected override void OnRenderSeparator(ToolStripSeparatorRenderEventArgs e) {
   using (Pen pen = new Pen(Border)) e.Graphics.DrawLine(pen, P(12), e.Item.Height/2, e.Item.Width-P(12), e.Item.Height/2);
  }
  protected override void OnRenderArrow(ToolStripArrowRenderEventArgs e) {
   int x = e.Item.Width-P(16), y = e.Item.Height/2;
   e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
   using (Pen pen = new Pen(e.Item.Enabled ? Muted : Border, Math.Max(1, UiScale))) {
    e.Graphics.DrawLines(pen, new Point[] {new Point(x-P(2), y-P(3)), new Point(x+P(1), y), new Point(x-P(2), y+P(3))});
   }
  }
  private void Layout(Graphics g, string mode, Rectangle r, Color color) {
   g.SmoothingMode = SmoothingMode.AntiAlias;
   using (Pen pen = new Pen(color, Math.Max(1, UiScale))) {
    g.DrawRectangle(pen, r.X, r.Y, r.Width, r.Height);
    int band = P(4);
    using (Brush brush = new SolidBrush(color)) {
     if (mode == "title") g.FillRectangle(brush, r.X+P(2), r.Y+P(2), r.Width-P(4), band);
     else if (mode == "toolbar") g.FillRectangle(brush, r.X+P(5), r.Y+P(7), r.Width-P(7), band);
     else if (mode == "bottom") g.FillRectangle(brush, r.X+P(5), r.Bottom-P(6), r.Width-P(7), band);
     else g.FillRectangle(brush, r.X+P(2), r.Y+P(4), P(7), r.Height-P(6));
    }
   }
  }
  protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e) {
   MenuEntry item = e.Item as MenuEntry;
   if (item == null) { base.OnRenderItemText(e); return; }
   Graphics g = e.Graphics; int h = item.Height, w = item.Width;
   TextFormatFlags flags = TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine;
   if (item.Kind == "section") {
    using (Font font = new Font(item.Font.FontFamily, item.Font.Size * 0.86F, FontStyle.Regular, item.Font.Unit))
     TextRenderer.DrawText(g, item.Text, font, new Rectangle(P(12), P(3), w-P(24), h-P(3)), Muted, flags);
    return;
   }
   Color ink = Ink(item);
   int iconX = P(12), textX = P(43), textRight = P(38);
   int iconY = item.Detail.Length > 0 ? P(12) : (h-P(18))/2;
   if (item.Kind == "summary") {
    g.SmoothingMode = SmoothingMode.AntiAlias;
    using (Brush brush = new SolidBrush(Hover)) using (GraphicsPath shape = Rounded(new Rectangle(P(10), P(12), P(30), P(30)), P(9))) g.FillPath(brush, shape);
    iconX = P(16); iconY = P(18); textX = P(50); textRight = P(12);
   }
   if (!item.Swatch.IsEmpty) {
    g.SmoothingMode = SmoothingMode.AntiAlias;
    using (Brush brush = new SolidBrush(item.Swatch)) g.FillEllipse(brush, iconX, iconY, P(18), P(18));
    using (Pen pen = new Pen(Border)) g.DrawEllipse(pen, iconX, iconY, P(18), P(18));
   } else if (item.LayoutIcon.Length > 0) {
    Layout(g, item.LayoutIcon, new Rectangle(P(9), (h-P(20))/2, P(25), P(20)), item.Checked ? Accent : Muted);
   } else if (item.Glyph.Length > 0) {
    using (Font glyphFont = new Font("Segoe MDL2 Assets", 16F * UiScale, FontStyle.Regular, GraphicsUnit.Pixel))
     TextRenderer.DrawText(g, item.Glyph, glyphFont, new Rectangle(iconX, iconY, P(20), P(20)), item.Kind == "summary" ? Accent : (item.Tone.Length > 0 ? ink : Muted), TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
   }
   bool twoLines = item.Detail.Length > 0;
   int titleY = twoLines ? P(item.Kind == "summary" ? 9 : 4) : 0;
   int titleH = twoLines ? P(24) : h;
   using (Font font = new Font(item.Font, item.Kind == "summary" ? FontStyle.Bold : FontStyle.Regular))
    TextRenderer.DrawText(g, item.Text, font, new Rectangle(textX, titleY, w-textX-textRight, titleH), ink, flags);
   if (twoLines) {
    using (Font font = new Font(item.Font.FontFamily, item.Font.Size * 0.84F, FontStyle.Regular, item.Font.Unit))
     TextRenderer.DrawText(g, item.Detail, font, new Rectangle(textX, titleY+P(23), w-textX-textRight, P(18)), Muted, flags);
   }
   if (item.Checked) {
    int x = w-P(item.HasDropDownItems ? 36 : 23), y = h/2;
    g.SmoothingMode = SmoothingMode.AntiAlias;
    using (Pen pen = new Pen(Accent, Math.Max(1.5F, 1.6F*UiScale))) {
     pen.StartCap = LineCap.Round; pen.EndCap = LineCap.Round;
     g.DrawLines(pen, new Point[] {new Point(x-P(4),y), new Point(x-P(1),y+P(3)), new Point(x+P(5),y-P(4))});
    }
   }
  }
 }
}
'@
}
function Convert-QmMenuColor([string]$hex,[Drawing.Color]$background=[Drawing.Color]::White) {
 $c=[Windows.Media.ColorConverter]::ConvertFromString($hex)
 if($c.A -eq 255){return [Drawing.Color]::FromArgb($c.R,$c.G,$c.B)}
 $a=$c.A/255.0
 return [Drawing.Color]::FromArgb([int][math]::Round($c.R*$a+$background.R*(1-$a)),[int][math]::Round($c.G*$a+$background.G*(1-$a)),[int][math]::Round($c.B*$a+$background.B*(1-$a)))
}
function New-QmPopup([string]$skin,[double]$scale=1) {
 $t=$script:QM_SKINS[$skin]
 $m=[QoderMeter.MeterMenu]::new([single]$scale)
 $r=[QoderMeter.MenuRenderer]::new();$r.UiScale=$scale
 # Popup surfaces are opaque; blend the bar's translucent colors onto that base.
 $raw=[Windows.Media.ColorConverter]::ConvertFromString($t.bg)
 $r.Background=[Drawing.Color]::FromArgb($raw.R,$raw.G,$raw.B)
 $r.Foreground=Convert-QmMenuColor $t.text $r.Background;$r.Muted=Convert-QmMenuColor $t.gray $r.Background
 $r.Border=Convert-QmMenuColor $t.border $r.Background;$r.Hover=Convert-QmMenuColor $t.grayTint $r.Background
 $r.Accent=Convert-QmMenuColor $t.green $r.Background;$r.Danger=Convert-QmMenuColor $t.red $r.Background;$r.Gold=Convert-QmMenuColor $t.gold $r.Background
 $m.Renderer=$r;$m.BackColor=$r.Background;$m.ForeColor=$r.Foreground
 $m.Tag=@{Scale=$scale;Skin=$skin};return $m
}
function Set-QmMenuEntryStyle($item,[string]$icon='', [string]$detail='', [string]$tone='') {
 $glyphs=@{meter=0xE9D9;settings=0xE713;show=0xE890;hide=0xED1A;follow=0xE8B7;session=0xE8F2;layout=0xE8A9;font=0xE8D2;palette=0xE790;fields=0xE8FD;account=0xE77B;gift=0xE719;history=0xE81C;link=0xE774;power=0xE7E8;refresh=0xE72C;folder=0xE8B7;reset=0xE777;more=0xE712;exit=0xE8BB;token=0xE8A5;speed=0xE945;clock=0xE823;credit=0xE8D4;tools=0xE90F;status=0xE946;auto=0xE793}
 if($glyphs.ContainsKey($icon)){$item.Glyph=[string][char]$glyphs[$icon]}
 $item.Detail=$detail;$item.Tone=$tone
 $item.AccessibleName=$item.Text;$item.AccessibleDescription=$detail
}
function Add-QmMenuHeading($parent,[string]$text,[string]$detail='') {
 $item=Add-QmMenu $parent $text '' $null
 $item.Kind=$(if($detail){'summary'}else{'section'});$item.Enabled=$false
 Set-QmMenuEntryStyle $item $(if($detail){'meter'}else{''}) $detail
 return $item
}
