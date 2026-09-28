using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Threading;
using System.Windows.Forms;

namespace BiblioRfid.Launcher
{
    internal static class Program
    {
        private const string Address = "http://127.0.0.1:4310";

        [STAThread]
        private static void Main(string[] args)
        {
            try
            {
                string root = AppDomain.CurrentDomain.BaseDirectory;
                string server = Path.Combine(root, "server.js");
                if (!File.Exists(server))
                {
                    string packagedRoot = Path.Combine(root, "BiblioRFID-Windows-1.0.0");
                    if (File.Exists(Path.Combine(packagedRoot, "server.js")))
                    {
                        root = packagedRoot;
                        server = Path.Combine(root, "server.js");
                    }
                }
                if (!File.Exists(server))
                    throw new FileNotFoundException("Le serveur BiblioRFID est introuvable.", server);

                if (!ServerIsReady())
                {
                    string bundledNode = Path.Combine(root, "runtime", "node.exe");
                    string node = File.Exists(bundledNode) ? bundledNode : "node.exe";
                    ProcessStartInfo start = new ProcessStartInfo
                    {
                        FileName = node,
                        Arguments = "\"" + server + "\"",
                        WorkingDirectory = root,
                        UseShellExecute = false,
                        CreateNoWindow = true,
                        WindowStyle = ProcessWindowStyle.Hidden
                    };
                    Process process = Process.Start(start);
                    if (process == null) throw new InvalidOperationException("Le serveur local n'a pas pu démarrer.");

                    DateTime deadline = DateTime.UtcNow.AddSeconds(20);
                    while (DateTime.UtcNow < deadline && !ServerIsReady()) Thread.Sleep(250);
                    if (!ServerIsReady())
                        throw new InvalidOperationException("Le serveur local BiblioRFID ne répond pas.");
                }

                bool openBrowser = Array.IndexOf(args, "--no-open") < 0;
                if (openBrowser)
                    Process.Start(new ProcessStartInfo(Address) { UseShellExecute = true });
            }
            catch (Exception error)
            {
                MessageBox.Show(
                    error.GetBaseException().Message,
                    "BiblioRFID",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error
                );
            }
        }

        private static bool ServerIsReady()
        {
            try
            {
                HttpWebRequest request = (HttpWebRequest)WebRequest.Create(Address);
                request.Method = "GET";
                request.Timeout = 700;
                request.AllowAutoRedirect = false;
                using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
                    return (int)response.StatusCode >= 200 && (int)response.StatusCode < 500;
            }
            catch
            {
                return false;
            }
        }
    }
}
