using System;
using System.Diagnostics;
using System.IO;

internal static class StartDemoLauncher
{
    private static string Quote(string value)
    {
        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }

    [STAThread]
    private static int Main(string[] args)
    {
        Console.Title = "Thesis Fleet Manager Demo";

        string repositoryRoot = AppDomain.CurrentDomain.BaseDirectory;
        string scriptPath = Path.Combine(repositoryRoot, "scripts", "start-demo.ps1");
        if (!File.Exists(scriptPath))
        {
            Console.Error.WriteLine("Missing launcher script: " + scriptPath);
            Console.WriteLine("Press any key to close.");
            Console.ReadKey(true);
            return 1;
        }

        string forwardedArguments = string.Empty;
        if (args.Length > 0)
        {
            forwardedArguments = " " + string.Join(" ", Array.ConvertAll(args, Quote));
        }

        ProcessStartInfo startInfo = new ProcessStartInfo();
        startInfo.FileName = "powershell.exe";
        startInfo.Arguments =
            "-NoLogo -NoProfile -ExecutionPolicy Bypass -File " +
            Quote(scriptPath) + forwardedArguments;
        startInfo.WorkingDirectory = repositoryRoot;
        startInfo.UseShellExecute = false;

        try
        {
            using (Process process = Process.Start(startInfo))
            {
                process.WaitForExit();
                if (process.ExitCode != 0)
                {
                    Console.Error.WriteLine();
                    Console.Error.WriteLine("The demo launcher stopped with an error.");
                    Console.WriteLine("Press any key to close.");
                    Console.ReadKey(true);
                }
                return process.ExitCode;
            }
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine("Unable to start the demo: " + exception.Message);
            Console.WriteLine("Press any key to close.");
            Console.ReadKey(true);
            return 1;
        }
    }
}
