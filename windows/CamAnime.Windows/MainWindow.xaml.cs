using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Input;
using Microsoft.Web.WebView2.Core;

namespace CamAnime.Windows;

public partial class MainWindow : Window
{
    /// <summary>Hidden in-app library. Files never leave this folder automatically.</summary>
    private static readonly string LibraryDir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "CamAnime", "Library");

    private bool _initialized;

    public MainWindow()
    {
        InitializeComponent();
        Directory.CreateDirectory(LibraryDir);
        Loaded += async (_, _) => await InitAsync();
    }

    private async Task InitAsync()
    {
        if (_initialized) return;
        _initialized = true;

        AddressBox.Text = App.ApiBase + "/";
        StatusText.Text = $"Linked to {App.ApiBase} — downloads go to the hidden in-app library.";

        await Web.EnsureCoreWebView2Async();

        // Route every download into the hidden library instead of the user's Downloads folder.
        Web.CoreWebView2.DownloadStarting += OnDownloadStarting;
        Web.CoreWebView2.NavigationCompleted += (_, e) =>
            StatusText.Text = e.IsSuccess
                ? $"{Web.Source} — downloads stay in the in-app library."
                : $"Navigation failed ({e.WebErrorStatus}). Check the app URL: {App.ApiBase}";

        // Remove ads/trackers requested by the page (no third-party ad hosts allowed).
        var blocked = new[] { "doubleclick.net", "googlesyndication.com", "adservice.google.com",
                              "popads.net", "propellerads.com", "adsterra", "onclickads" };
        Web.CoreWebView2.AddWebResourceRequestedFilter("*", CoreWebView2WebResourceContext.All);
        Web.CoreWebView2.WebResourceRequested += (_, e) =>
        {
            var uri = e.Request.Uri ?? "";
            foreach (var b in blocked)
            {
                if (uri.Contains(b, StringComparison.OrdinalIgnoreCase))
                {
                    e.Response = Web.CoreWebView2.Environment.CreateWebResourceResponse(
                        null, 403, "Blocked", "Content-Type: text/plain");
                    return;
                }
            }
        };

        Web.CoreWebView2.Navigate(AddressBox.Text);
    }

    private void OnDownloadStarting(object? sender, CoreWebView2DownloadStartingEventArgs e)
    {
        var name = Path.GetFileName(e.ResultFilePath);
        if (string.IsNullOrWhiteSpace(name)) name = $"camanime_{DateTime.Now:yyyyMMdd_HHmmss}.mp4";
        e.ResultFilePath = Path.Combine(LibraryDir, name);
        e.Handled = true;

        var item = e.DownloadOperation;
        item.StateChanged += (_, _) =>
        {
            if (item.State == CoreWebView2DownloadState.Completed)
                Dispatcher.Invoke(() => StatusText.Text = $"Saved to in-app library: {name} — use Library → Save to device to export.");
        };
        StatusText.Text = $"Downloading into hidden library: {name} ({(item.TotalBytesToReceive > 0 ? ((long)item.BytesReceived * 100 / (long)(item.TotalBytesToReceive ?? 1)) + "%" : "…")})";
    }

    private void Library_Click(object sender, RoutedEventArgs e)
    {
        var win = new LibraryWindow(LibraryDir);
        win.ShowDialog();
        StatusText.Text = $"Library: {LibraryDir}";
    }

    private void Back_Click(object sender, RoutedEventArgs e) { if (Web.CoreWebView2?.CanGoBack == true) Web.CoreWebView2.GoBack(); }
    private void Forward_Click(object sender, RoutedEventArgs e) { if (Web.CoreWebView2?.CanGoForward == true) Web.CoreWebView2.GoForward(); }
    private void Reload_Click(object sender, RoutedEventArgs e) => Web.CoreWebView2?.Reload();

    private void Address_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Enter || Web.CoreWebView2 is null) return;
        var text = AddressBox.Text.Trim();
        if (text.Length == 0) return;
        if (!text.StartsWith("http")) text = App.ApiBase + (text.StartsWith('/') ? text : "/" + text);
        Web.CoreWebView2.Navigate(text);
    }
}
