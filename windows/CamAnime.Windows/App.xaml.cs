using System.Windows;
using Microsoft.Web.WebView2.Core;

namespace CamAnime.Windows;

public partial class App : Application
{
    public static string ApiBase { get; private set; } = "http://localhost:3000";

    protected override void OnStartup(StartupEventArgs e)
    {
        // Optional: CamAnime.exe https://your-host
        if (e.Args.Length > 0 && (e.Args[0].StartsWith("http://") || e.Args[0].StartsWith("https://")))
        {
            ApiBase = e.Args[0].TrimEnd('/');
        }
        else
        {
            var env = Environment.GetEnvironmentVariable("CAMANIME_URL");
            if (!string.IsNullOrWhiteSpace(env)) ApiBase = env.TrimEnd('/');
        }

        // Keep downloads inside the app profile; user copies out explicitly.
        var userData = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "CamAnime", "WebView2");
        Directory.CreateDirectory(userData);
        Environment.SetEnvironmentVariable("WEBVIEW2_USER_DATA_FOLDER", userData);
        _ = CoreWebView2Environment.GetAvailableBrowserVersionString();
        base.OnStartup(e);
    }
}
