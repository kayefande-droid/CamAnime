using System.IO;
using System.Windows;

namespace CamAnime.Windows;

public partial class LibraryWindow : Window
{
    private readonly string _dir;

    public LibraryWindow(string dir)
    {
        InitializeComponent();
        _dir = dir;
        Refresh();
    }

    private void Refresh()
    {
        Files.Items.Clear();
        foreach (var f in Directory.EnumerateFiles(_dir).OrderByDescending(File.GetLastWriteTimeUtc))
            Files.Items.Add(Path.GetFileName(f));
    }

    private string? Selected()
    {
        var name = Files.SelectedItem as string;
        return name is null ? null : Path.Combine(_dir, name);
    }

    private void Save_Click(object sender, RoutedEventArgs e)
    {
        var path = Selected();
        if (path is null) { MessageBox.Show("Select a download first."); return; }

        var dlg = new Microsoft.Win32.SaveFileDialog
        {
            FileName = Path.GetFileName(path),
            InitialDirectory = Environment.GetFolderPath(Environment.SpecialFolder.MyVideos),
            Filter = "Video|*.mp4|All files|*.*"
        };
        if (dlg.ShowDialog() != true) return;

        try
        {
            File.Copy(path, dlg.FileName, overwrite: true);
            MessageBox.Show($"Saved to device:\n{dlg.FileName}");
        }
        catch (Exception ex)
        {
            MessageBox.Show($"Save failed: {ex.Message}");
        }
    }

    private void Delete_Click(object sender, RoutedEventArgs e)
    {
        var path = Selected();
        if (path is null) return;
        try { File.Delete(path); Refresh(); }
        catch (Exception ex) { MessageBox.Show($"Delete failed: {ex.Message}"); }
    }
}
