// TaskScheduler R3-O local OCR host (template engine "windows-media-ocr").
//
// Why a separate EXE?
//   * The recogniser is the OCR engine that ships with Windows 10/11
//     (Windows.Media.Ocr). It is an OS component: nothing has to be bundled and
//     nothing is downloaded, so the package stays offline and licence-clean.
//   * Flutter/Dart cannot call WinRT directly without extra native plumbing, so
//     the work happens in this tiny full-trust .NET Framework 4.8 console host.
//     A bounded child process also gives the UI a real, killable unit of work.
//   * PDF pages are rasterised by Windows.Data.Pdf (also an OS component). No
//     third-party PDF library, no Tesseract data files, no Python.
//
// Contract with the Dart client (flutter_app/lib/src/state/ocr/):
//   * stdout: one UTF-8 JSON object per line (JSONL). Keys are fixed, see
//     Emit* methods below. stderr carries diagnostics only.
//   * exit code: 0 all requested pages recognised, 1 partial success (some page
//     failed, at least one succeeded), 2 nothing could be done (bad arguments,
//     encrypted/corrupt source, no OCR language, every page failed), 3 the
//     the parent process disappeared (stdin watchdog).
//
// Privacy/offline guarantees: no network code, no file enumeration, the source
// document is opened read-only and never modified, rendered pages stay in
// memory (nothing is written to disk), only the given file is read.
//
// Build: scripts/build_ocr_host.ps1 (csc, references Windows.winmd plus
// System.Runtime / System.Runtime.WindowsRuntime from the .NET Framework dir).
// Keep this file C# 5 compatible: the Windows-bundled csc.exe only supports 5.0.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Windows.Data.Pdf;
using Windows.Globalization;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;
using Windows.Storage.Streams;

internal static class HostInfo
{
    public const string Name = "taskscheduler-ocr-host";
    public const string Version = "1.0.0";
    public const string EngineName = "Windows.Media.Ocr";

    /// <summary>Engine identity used in cache keys: engine + OS build.</summary>
    public static string EngineVersion
    {
        get { return EngineName + "/" + Environment.OSVersion.Version.ToString(); }
    }
}

internal sealed class UsageException : Exception
{
    public UsageException(string message) : base(message) { }
}

/// <summary>A fatal, whole-job condition (maps to an error event with page 0).</summary>
internal sealed class HostException : Exception
{
    public readonly string Code;

    public HostException(string code, string message) : base(message)
    {
        Code = code;
    }

    public HostException(string code, string message, Exception inner) : base(message, inner)
    {
        Code = code;
    }
}

internal sealed class Limits
{
    public long MaxPixels = 40000000L;   // 40 MP per rendered page
    public int MaxDimension = 10000;     // OCR engine refuses very large bitmaps
    public int MaxPages = 500;           // per job
    public int Dpi = 150;
    public const int MinDpi = 72;
    public const int MaxDpi = 600;
}

internal sealed class Options
{
    public bool Probe = false;
    public bool Info = false;
    public string Mode = "";             // probe | info | pdf | image
    public string PdfPath = "";
    public string ImagePath = "";
    public string PagesSpec = "";
    public readonly List<string> Languages = new List<string>();
    public string Password = "";
    public readonly Limits Limits = new Limits();
    public bool WatchStdin = false;
    public bool ShowHelp = false;
    public readonly List<int> RequestedPages = new List<int>();
}

internal sealed class LangInfo
{
    public string Tag = "";
    public string DisplayName = "";
    public string NativeName = "";
    public bool Recognizer = true;
}

internal sealed class OcrLineInfo
{
    public string Text = "";
    public double X;
    public double Y;
    public double Width;
    public double Height;
}

internal sealed class OcrPageOutcome
{
    public int Page;
    public string Text = "";
    public readonly List<OcrLineInfo> Lines = new List<OcrLineInfo>();
    public uint Width;
    public uint Height;
    public int Dpi;
    public string Language = "";
    public double Score;
}

internal static class Json
{
    public static string Str(string value)
    {
        if (value == null) return "null";
        var sb = new StringBuilder(value.Length + 8);
        AppendStr(sb, value);
        return sb.ToString();
    }

    public static void AppendStr(StringBuilder sb, string value)
    {
        if (value == null)
        {
            sb.Append("null");
            return;
        }
        sb.Append('"');
        for (var i = 0; i < value.Length; i++)
        {
            var c = value[i];
            switch (c)
            {
                case '"': sb.Append("\\\""); break;
                case '\\': sb.Append("\\\\"); break;
                case '\b': sb.Append("\\b"); break;
                case '\f': sb.Append("\\f"); break;
                case '\n': sb.Append("\\n"); break;
                case '\r': sb.Append("\\r"); break;
                case '\t': sb.Append("\\t"); break;
                default:
                    if (c < ' ' || c == '\u2028' || c == '\u2029')
                    {
                        sb.Append("\\u");
                        sb.Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                    }
                    else
                    {
                        sb.Append(c);
                    }
                    break;
            }
        }
        sb.Append('"');
    }

    public static string Num(double value)
    {
        if (double.IsNaN(value) || double.IsInfinity(value)) value = 0;
        return Math.Round(value, 1).ToString("0.#", CultureInfo.InvariantCulture);
    }

    public static string Int(long value)
    {
        return value.ToString(CultureInfo.InvariantCulture);
    }
}

internal sealed class EventWriter
{
    private readonly StreamWriter _out;
    private readonly Stopwatch _clock = Stopwatch.StartNew();

    public EventWriter(StreamWriter output)
    {
        _out = output;
    }

    public void Ready(string mode, int pages, string source, List<LangInfo> languages)
    {
        var sb = new StringBuilder();
        sb.Append("{\"event\":\"ready\",\"mode\":");
        Json.AppendStr(sb, mode);
        sb.Append(",\"host\":").Append(Json.Str(HostInfo.Name));
        sb.Append(",\"hostVersion\":").Append(Json.Str(HostInfo.Version));
        sb.Append(",\"engine\":").Append(Json.Str(HostInfo.EngineName));
        sb.Append(",\"engineVersion\":").Append(Json.Str(HostInfo.EngineVersion));
        sb.Append(",\"osVersion\":").Append(Json.Str(Environment.OSVersion.Version.ToString()));
        sb.Append(",\"pages\":").Append(Json.Int(pages));
        if (source != null) sb.Append(",\"source\":").Append(Json.Str(source));
        sb.Append(",\"languages\":");
        AppendLanguages(sb, languages);
        sb.Append('}');
        WriteLine(sb.ToString());
    }

    public void Probe(List<LangInfo> languages, int missingCount)
    {
        var sb = new StringBuilder();
        sb.Append("{\"event\":\"probe\",\"engine\":").Append(Json.Str(HostInfo.EngineName));
        sb.Append(",\"hostVersion\":").Append(Json.Str(HostInfo.Version));
        sb.Append(",\"osVersion\":").Append(Json.Str(Environment.OSVersion.Version.ToString()));
        sb.Append(",\"languageCount\":").Append(Json.Int(languages.Count));
        sb.Append(",\"recognizerAvailable\":").Append(languages.Count > 0 ? "true" : "false");
        sb.Append(",\"unavailableRequested\":").Append(Json.Int(missingCount));
        sb.Append(",\"languages\":");
        AppendLanguages(sb, languages);
        sb.Append('}');
        WriteLine(sb.ToString());
    }

    public void Info(int pages, bool encrypted, string kind, List<string> pageSizes)
    {
        var sb = new StringBuilder();
        sb.Append("{\"event\":\"info\",\"source\":").Append(Json.Str(kind));
        sb.Append(",\"pages\":").Append(Json.Int(pages));
        sb.Append(",\"encrypted\":").Append(encrypted ? "true" : "false");
        sb.Append(",\"pageSizes\":[");
        for (var i = 0; i < pageSizes.Count; i++)
        {
            if (i > 0) sb.Append(',');
            sb.Append(pageSizes[i]);
        }
        sb.Append("]}");
        WriteLine(sb.ToString());
    }

    public void Page(int page, int index, int total, uint width, uint height, int dpi, bool scaled)
    {
        var sb = new StringBuilder();
        sb.Append("{\"event\":\"page\",\"page\":").Append(Json.Int(page));
        sb.Append(",\"index\":").Append(Json.Int(index));
        sb.Append(",\"total\":").Append(Json.Int(total));
        sb.Append(",\"width\":").Append(Json.Int(width));
        sb.Append(",\"height\":").Append(Json.Int(height));
        sb.Append(",\"dpi\":").Append(Json.Int(dpi));
        sb.Append(",\"scaled\":").Append(scaled ? "true" : "false");
        sb.Append('}');
        WriteLine(sb.ToString());
    }

    public void Result(OcrPageOutcome outcome, int total, long elapsedMs)
    {
        var sb = new StringBuilder(4096);
        sb.Append("{\"event\":\"result\",\"page\":").Append(Json.Int(outcome.Page));
        sb.Append(",\"total\":").Append(Json.Int(total));
        sb.Append(",\"method\":\"ocr\"");
        sb.Append(",\"engine\":").Append(Json.Str(HostInfo.EngineName));
        sb.Append(",\"engineVersion\":").Append(Json.Str(HostInfo.EngineVersion));
        sb.Append(",\"language\":").Append(Json.Str(outcome.Language));
        sb.Append(",\"dpi\":").Append(Json.Int(outcome.Dpi));
        sb.Append(",\"width\":").Append(Json.Int(outcome.Width));
        sb.Append(",\"height\":").Append(Json.Int(outcome.Height));
        sb.Append(",\"elapsedMs\":").Append(Json.Int(elapsedMs));
        sb.Append(",\"text\":");
        Json.AppendStr(sb, outcome.Text);
        sb.Append(",\"lines\":[");
        for (var i = 0; i < outcome.Lines.Count; i++)
        {
            var line = outcome.Lines[i];
            if (i > 0) sb.Append(',');
            sb.Append("{\"text\":");
            Json.AppendStr(sb, line.Text);
            // Windows.Media.Ocr exposes no per-word confidence. Emitting a made-up
            // number would be worse than emitting null; the Dart layer flags
            // date/time/number fields for user confirmation instead.
            sb.Append(",\"confidence\":null,\"bbox\":[");
            sb.Append(Json.Num(line.X)).Append(',');
            sb.Append(Json.Num(line.Y)).Append(',');
            sb.Append(Json.Num(line.Width)).Append(',');
            sb.Append(Json.Num(line.Height));
            sb.Append("]}");
        }
        sb.Append("]}");
        WriteLine(sb.ToString());
    }

    public void Error(int page, string code, string message, long elapsedMs)
    {
        var sb = new StringBuilder();
        sb.Append("{\"event\":\"error\",\"page\":").Append(Json.Int(page));
        sb.Append(",\"code\":").Append(Json.Str(code));
        sb.Append(",\"message\":").Append(Json.Str(message));
        sb.Append(",\"elapsedMs\":").Append(Json.Int(elapsedMs));
        sb.Append('}');
        WriteLine(sb.ToString());
    }

    public void Done(int pages, int ok, int failed, bool cancelled)
    {
        var sb = new StringBuilder();
        sb.Append("{\"event\":\"done\",\"pages\":").Append(Json.Int(pages));
        sb.Append(",\"ok\":").Append(Json.Int(ok));
        sb.Append(",\"failed\":").Append(Json.Int(failed));
        sb.Append(",\"cancelled\":").Append(cancelled ? "true" : "false");
        sb.Append(",\"elapsedMs\":").Append(Json.Int(_clock.ElapsedMilliseconds));
        sb.Append('}');
        WriteLine(sb.ToString());
    }

    private static void AppendLanguages(StringBuilder sb, List<LangInfo> languages)
    {
        sb.Append('[');
        for (var i = 0; i < languages.Count; i++)
        {
            var lang = languages[i];
            if (i > 0) sb.Append(',');
            sb.Append("{\"tag\":").Append(Json.Str(lang.Tag));
            sb.Append(",\"displayName\":").Append(Json.Str(lang.DisplayName));
            sb.Append(",\"nativeName\":").Append(Json.Str(lang.NativeName));
            sb.Append(",\"recognizer\":").Append(lang.Recognizer ? "true" : "false");
            sb.Append('}');
        }
        sb.Append(']');
    }

    private void WriteLine(string line)
    {
        _out.Write(line);
        _out.Write('\n');
        _out.Flush();
    }
}

internal static class Program
{
    private static StreamWriter _out;
    private static StreamWriter _err;
    private static EventWriter _events;
    private static readonly List<OcrEngine> Engines = new List<OcrEngine>();
    private static readonly List<LangInfo> EngineLanguages = new List<LangInfo>();
    private static readonly List<LangInfo> AvailableLanguages = new List<LangInfo>();
    private static readonly object RenderScaleLock = new object();
    private static double _renderScale = 0.0; // rendered pixels per DestinationWidth unit

    private static int Main(string[] args)
    {
        _out = new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false));
        _out.NewLine = "\n";
        _out.AutoFlush = true;
        _err = new StreamWriter(Console.OpenStandardError(), new UTF8Encoding(false));
        _err.NewLine = "\n";
        _err.AutoFlush = true;
        _events = new EventWriter(_out);

        try
        {
            var options = ParseArgs(args);
            if (options.ShowHelp)
            {
                WriteUsage();
                return 0;
            }
            if (options.WatchStdin) StartStdinWatchdog();
            return Run(options).GetAwaiter().GetResult();
        }
        catch (UsageException usage)
        {
            _err.WriteLine("[ocr_host] usage: " + usage.Message);
            WriteUsage();
            return 2;
        }
        catch (HostException fatal)
        {
            // Whole-job failure: one error event + done so a JSONL consumer can
            // finish deterministically, then exit 2.
            _events.Error(0, fatal.Code, fatal.Message, 0);
            _events.Done(0, 0, 0, false);
            _err.WriteLine("[ocr_host] fatal: " + fatal.Code + ": " + fatal.Message);
            return 2;
        }
        catch (Exception ex)
        {
            _events.Error(0, "render_failed", "OCR 宿主内部错误：" + ShortError(ex), 0);
            _events.Done(0, 0, 0, false);
            _err.WriteLine("[ocr_host] unexpected: " + ex);
            return 2;
        }
        finally
        {
            try { _out.Flush(); } catch (Exception) { }
        }
    }

    private static async Task<int> Run(Options options)
    {
        LoadAvailableLanguages();

        if (options.Mode == "probe")
        {
            _events.Ready("probe", 0, null, AvailableLanguages);
            _events.Probe(AvailableLanguages, 0);
            _events.Done(0, 0, 0, false);
            return AvailableLanguages.Count > 0 ? 0 : 2;
        }

        if (options.Mode == "info")
        {
            // Page count / dimensions only: must work even when no OCR language
            // pack is installed, because the Dart layer uses it to plan pages.
            return await RunInfo(options);
        }

        ResolveEngines(options);

        if (options.Mode == "pdf")
        {
            return await RunPdf(options);
        }
        if (options.Mode == "image")
        {
            return await RunImage(options);
        }

        throw new UsageException("必须指定 --probe、--info、--pdf 或 --image 之一。");
    }

    // ---------------------------------------------------------------- arguments

    private static Options ParseArgs(string[] args)
    {
        var options = new Options();
        for (var i = 0; i < args.Length; i++)
        {
            var arg = args[i];
            switch (arg)
            {
                case "--probe":
                    options.Probe = true;
                    break;
                case "--info":
                    options.Info = true;
                    break;
                case "--pdf":
                    if (options.PdfPath.Length > 0) throw new UsageException("--pdf 只能出现一次。");
                    options.PdfPath = RequireValue(args, ref i, "--pdf");
                    break;
                case "--image":
                    if (options.ImagePath.Length > 0) throw new UsageException("--image 只能出现一次。");
                    options.ImagePath = RequireValue(args, ref i, "--image");
                    break;
                case "--pages":
                    options.PagesSpec = RequireValue(args, ref i, "--pages");
                    break;
                case "--lang":
                case "--languages":
                    foreach (var tag in RequireValue(args, ref i, arg).Split(','))
                    {
                        var trimmed = tag.Trim();
                        if (trimmed.Length > 0) options.Languages.Add(trimmed);
                    }
                    break;
                case "--dpi":
                    options.Limits.Dpi = ParseInt(RequireValue(args, ref i, "--dpi"), "--dpi");
                    break;
                case "--password":
                    options.Password = RequireValue(args, ref i, "--password");
                    break;
                case "--max-pixels":
                    options.Limits.MaxPixels = ParseLong(RequireValue(args, ref i, "--max-pixels"), "--max-pixels");
                    break;
                case "--max-dimension":
                    options.Limits.MaxDimension = ParseInt(RequireValue(args, ref i, "--max-dimension"), "--max-dimension");
                    break;
                case "--max-pages":
                    options.Limits.MaxPages = ParseInt(RequireValue(args, ref i, "--max-pages"), "--max-pages");
                    break;
                case "--watch-stdin":
                    options.WatchStdin = true;
                    break;
                case "--help":
                case "-h":
                    options.ShowHelp = true;
                    break;
                default:
                    throw new UsageException("未知参数：" + arg);
            }
        }

        if (options.PdfPath.Length > 0 && options.ImagePath.Length > 0)
        {
            throw new UsageException("--pdf 与 --image 不能同时使用。");
        }
        if (options.Probe)
        {
            if (options.Info || options.PdfPath.Length > 0 || options.ImagePath.Length > 0)
            {
                throw new UsageException("--probe 不能与其它模式同时使用。");
            }
            options.Mode = "probe";
        }
        else if (options.Info)
        {
            if (options.PdfPath.Length == 0 && options.ImagePath.Length == 0)
            {
                throw new UsageException("--info 需要 --pdf 或 --image 参数。");
            }
            options.Mode = "info";
        }
        else if (options.PdfPath.Length > 0)
        {
            options.Mode = "pdf";
        }
        else if (options.ImagePath.Length > 0)
        {
            options.Mode = "image";
        }
        else if (!options.ShowHelp)
        {
            throw new UsageException("缺少模式参数。");
        }
        if (options.Limits.Dpi < Limits.MinDpi || options.Limits.Dpi > Limits.MaxDpi)
        {
            throw new UsageException("--dpi 必须在 " + Limits.MinDpi + " 到 " + Limits.MaxDpi + " 之间（收到 " + options.Limits.Dpi + "）。");
        }
        if (options.Limits.MaxPixels < 1000000L)
        {
            throw new UsageException("--max-pixels 必须至少为 1000000（收到 " + options.Limits.MaxPixels + "）。");
        }
        if (options.Limits.MaxDimension < 256 || options.Limits.MaxDimension > 32767)
        {
            throw new UsageException("--max-dimension 必须在 256 到 32767 之间（收到 " + options.Limits.MaxDimension + "）。");
        }
        if (options.Limits.MaxPages < 1 || options.Limits.MaxPages > 2000)
        {
            throw new UsageException("--max-pages 必须在 1 到 2000 之间（收到 " + options.Limits.MaxPages + "）。");
        }
        if (options.PagesSpec.Length > 0)
        {
            ParsePageSpec(options.PagesSpec, options.RequestedPages);
        }
        return options;
    }

    private static string RequireValue(string[] args, ref int index, string name)
    {
        if (index + 1 >= args.Length)
        {
            throw new UsageException(name + " 缺少参数值。");
        }
        index++;
        return args[index];
    }

    private static int ParseInt(string raw, string name)
    {
        int value;
        if (!int.TryParse(raw, NumberStyles.Integer, CultureInfo.InvariantCulture, out value))
        {
            throw new UsageException(name + " 需要整数（收到 " + raw + "）。");
        }
        return value;
    }

    private static long ParseLong(string raw, string name)
    {
        long value;
        if (!long.TryParse(raw, NumberStyles.Integer, CultureInfo.InvariantCulture, out value))
        {
            throw new UsageException(name + " 需要整数（收到 " + raw + "）。");
        }
        return value;
    }

    /// <summary>Parses "1-3,5,7-" (1-based, inclusive); "-" means "to the end".</summary>
    private static void ParsePageSpec(string spec, List<int> into)
    {
        var seen = new HashSet<int>();
        foreach (var rawPart in spec.Split(','))
        {
            var part = rawPart.Trim();
            if (part.Length == 0) continue;
            var dash = part.IndexOf('-');
            if (dash < 0)
            {
                var single = ParseInt(part, "--pages");
                if (single < 1) throw new UsageException("--pages 页码从 1 开始（收到 " + single + "）。");
                if (seen.Add(single)) into.Add(single);
                continue;
            }
            var from = dash == 0 ? 1 : ParseInt(part.Substring(0, dash), "--pages");
            var to = dash == part.Length - 1 ? int.MaxValue : ParseInt(part.Substring(dash + 1), "--pages");
            if (from < 1 || to < from) throw new UsageException("--pages 范围无效：" + part);
            for (var page = from; page <= to && page - from < 10000; page++)
            {
                if (seen.Add(page)) into.Add(page);
            }
        }
        into.Sort();
    }

    private static void WriteUsage()
    {
        _err.WriteLine("用法:");
        _err.WriteLine("  ocr_host.exe --probe");
        _err.WriteLine("  ocr_host.exe --info (--pdf <file> | --image <file>) [--password <pwd>]");
        _err.WriteLine("  ocr_host.exe --pdf <file> [--pages 1-3,5] [--lang zh-Hans-CN,en-US] [--dpi 150] [--password <pwd>]");
        _err.WriteLine("  ocr_host.exe --image <file> [--lang ...] [--dpi 150]");
        _err.WriteLine("  通用: [--max-pixels N] [--max-dimension N] [--max-pages N] [--watch-stdin]");
        _err.WriteLine("stdout 为 UTF-8 JSONL 事件（ready/page/result/error/done）；stderr 仅诊断。");
        _err.WriteLine("退出码: 0 全部成功, 1 部分成功, 2 无法处理/参数错误, 3 父进程已退出。");
    }

    private static void StartStdinWatchdog()
    {
        // The Dart client keeps the child's stdin pipe open for as long as the app
        // is alive. If the app crashes or is killed, the pipe closes and the
        // helper must not keep rendering/OCR-ing in the background.
        var thread = new Thread(delegate()
        {
            try
            {
                var stdin = Console.OpenStandardInput();
                var buffer = new byte[64];
                while (true)
                {
                    var read = stdin.Read(buffer, 0, buffer.Length);
                    if (read <= 0) break;
                }
            }
            catch (Exception)
            {
                // Fall through: a broken/closed stdin also means the parent is gone.
            }
            try { _err.WriteLine("[ocr_host] stdin closed (parent gone); aborting."); } catch (Exception) { }
            Environment.Exit(3);
        });
        thread.IsBackground = true;
        thread.Name = "stdin-watchdog";
        thread.Start();
    }

    private static string ShortError(Exception ex)
    {
        var text = ex.Message;
        if (text == null) return ex.GetType().Name;
        if (text.Length > 300) text = text.Substring(0, 300) + "…";
        return text;
    }

    // ---------------------------------------------------------------- languages

    private static void LoadAvailableLanguages()
    {
        AvailableLanguages.Clear();
        try
        {
            var available = OcrEngine.AvailableRecognizerLanguages;
            foreach (var language in available)
            {
                var info = new LangInfo();
                info.Tag = language.LanguageTag;
                info.DisplayName = language.DisplayName;
                info.NativeName = language.NativeName;
                info.Recognizer = true;
                AvailableLanguages.Add(info);
            }
        }
        catch (Exception ex)
        {
            _err.WriteLine("[ocr_host] cannot enumerate OCR languages: " + ShortError(ex));
        }
    }

    private static Language FindLanguage(string requested)
    {
        var wanted = (requested ?? "").Trim().ToLowerInvariant();
        if (wanted.Length == 0) return null;
        Language exact = null;
        Language prefix = null;
        foreach (var language in OcrEngine.AvailableRecognizerLanguages)
        {
            var tag = language.LanguageTag.ToLowerInvariant();
            if (tag == wanted)
            {
                exact = language;
                break;
            }
            if (prefix == null && TagMatches(wanted, tag)) prefix = language;
        }
        return exact ?? prefix;
    }

    private static bool TagMatches(string wanted, string available)
    {
        // zh / zh-cn / zh-hans / zh-hans-cn all map to a zh-Hans-* recogniser;
        // en / en-us etc. map to any en-* recogniser. Otherwise prefix match.
        if (wanted.StartsWith("zh") && available.StartsWith("zh-hans")) return true;
        if (wanted.StartsWith("en") && available.StartsWith("en")) return true;
        return available.StartsWith(wanted + "-") || wanted.StartsWith(available + "-");
    }

    private static void ResolveEngines(Options options)
    {
        Engines.Clear();
        EngineLanguages.Clear();
        var requested = new List<string>(options.Languages);
        if (requested.Count == 0)
        {
            // Sensible default: Chinese first (covers Latin too), then English,
            // then whatever the machine has.
            if (FindLanguage("zh-Hans-CN") != null) requested.Add("zh-Hans-CN");
            if (FindLanguage("en-US") != null) requested.Add("en-US");
            if (requested.Count == 0 && AvailableLanguages.Count > 0) requested.Add(AvailableLanguages[0].Tag);
        }

        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var missing = new List<string>();
        foreach (var tag in requested)
        {
            var language = FindLanguage(tag);
            if (language == null)
            {
                missing.Add(tag);
                continue;
            }
            if (!seen.Add(language.LanguageTag)) continue;
            var engine = OcrEngine.TryCreateFromLanguage(language);
            if (engine == null)
            {
                missing.Add(tag);
                continue;
            }
            var info = new LangInfo();
            info.Tag = language.LanguageTag;
            info.DisplayName = language.DisplayName;
            info.NativeName = language.NativeName;
            info.Recognizer = true;
            Engines.Add(engine);
            EngineLanguages.Add(info);
            _err.WriteLine("[ocr_host] OCR engine: " + language.LanguageTag);
        }

        if (missing.Count > 0)
        {
            _err.WriteLine("[ocr_host] requested OCR languages not installed: " + string.Join(",", missing.ToArray()));
        }
        if (Engines.Count == 0)
        {
            var available = new List<string>();
            foreach (var info in AvailableLanguages) available.Add(info.Tag);
            var hint = available.Count == 0
                ? "本机没有任何可用的 OCR 语言包"
                : "本机可用语言：" + string.Join(",", available.ToArray());
            throw new HostException(
                "no_language",
                "请求的语言（" + string.Join(",", requested.ToArray()) + "）在本机没有可用的 OCR 识别组件。" +
                hint + "。请在 Windows 设置 → 时间和语言 → 语言 中安装对应语言的“基本输入/光学字符识别”组件后重试。");
        }
    }

    // ------------------------------------------------------------------- info

    private static async Task<int> RunInfo(Options options)
    {
        if (options.Mode == "info" && options.PdfPath.Length == 0 && options.ImagePath.Length == 0)
        {
            throw new UsageException("--info 需要 --pdf 或 --image 参数。");
        }
        if (options.PdfPath.Length > 0)
        {
            using (var source = await OpenPdf(options.PdfPath, options.Password))
            {
                var count = (int)source.Document.PageCount;
                var sizes = new List<string>();
                for (var i = 0; i < count; i++)
                {
                    using (var page = source.Document.GetPage((uint)i))
                    {
                        var size = new StringBuilder();
                        size.Append("{\"page\":").Append(Json.Int(i + 1));
                        size.Append(",\"widthDip\":").Append(Json.Num(page.Size.Width));
                        size.Append(",\"heightDip\":").Append(Json.Num(page.Size.Height));
                        size.Append(",\"rotation\":").Append(Json.Str(page.Rotation.ToString()));
                        size.Append('}');
                        sizes.Add(size.ToString());
                    }
                }
                _events.Ready("info", count, "pdf", EngineLanguages);
                _events.Info(count, false, "pdf", sizes);
                _events.Done(count, count, 0, false);
                return 0;
            }
        }

        using (var stream = OpenReadStream(options.ImagePath))
        {
            var decoder = await BitmapDecoder.CreateAsync(stream);
            var imageSize = new StringBuilder();
            imageSize.Append("{\"page\":1,\"width\":").Append(Json.Int(decoder.PixelWidth));
            imageSize.Append(",\"height\":").Append(Json.Int(decoder.PixelHeight));
            imageSize.Append('}');
            _events.Ready("info", 1, "image", EngineLanguages);
            _events.Info(1, false, "image", new List<string> { imageSize.ToString() });
            _events.Done(1, 1, 0, false);
        }
        return 0;
    }

    // -------------------------------------------------------------------- pdf

    private sealed class PdfSource : IDisposable
    {
        public PdfDocument Document;
        public FileStream File;
        public IRandomAccessStream Stream;

        public void Dispose()
        {
            try { if (Document != null) Document = null; } catch (Exception) { }
            try { if (Stream != null) Stream.Dispose(); } catch (Exception) { }
            try { if (File != null) File.Dispose(); } catch (Exception) { }
        }
    }

    private static async Task<PdfSource> OpenPdf(string path, string password)
    {
        var source = new PdfSource();
        try
        {
            source.File = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
            source.Stream = source.File.AsRandomAccessStream();
            source.Document = await PdfDocument.LoadFromStreamAsync(source.Stream, password ?? "");
            return source;
        }
        catch (Exception ex)
        {
            source.Dispose();
            if (RawFileHasEncryptionMarker(path))
            {
                throw new HostException(
                    "encrypted",
                    "PDF 已加密（或密码不正确），无法渲染页面。" +
                    (string.IsNullOrEmpty(password) ? "请先解除密码保护，或提供文档密码后重试。" : "请确认文档密码。"),
                    ex);
            }
            if (ex is FileNotFoundException || ex is DirectoryNotFoundException)
            {
                throw new HostException("render_failed", "找不到 PDF 文件：路径不存在或不可访问。", ex);
            }
            throw new HostException("render_failed", "PDF 无法打开（可能已损坏或格式不受支持）：" + ShortError(ex), ex);
        }
    }

    private static bool RawFileHasEncryptionMarker(string path)
    {
        // Cheap structural check used only to pick a better error message. The
        // authoritative answer still comes from the OS renderer.
        try
        {
            using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                var size = stream.Length;
                var first = ReadAt(stream, 0, (int)Math.Min(1024 * 1024, size));
                var lastStart = Math.Max(0, size - 4 * 1024 * 1024);
                var last = ReadAt(stream, (int)lastStart, (int)(size - lastStart));
                return ContainsMarker(first) || ContainsMarker(last);
            }
        }
        catch (Exception)
        {
            return false;
        }
    }

    private static byte[] ReadAt(FileStream stream, int offset, int count)
    {
        var buffer = new byte[count];
        stream.Seek(offset, SeekOrigin.Begin);
        var read = 0;
        while (read < count)
        {
            var n = stream.Read(buffer, read, count - read);
            if (n <= 0) break;
            read += n;
        }
        if (read == count) return buffer;
        var smaller = new byte[read];
        Array.Copy(buffer, smaller, read);
        return smaller;
    }

    private static bool ContainsMarker(byte[] data)
    {
        var marker = Encoding.ASCII.GetBytes("/Encrypt");
        for (var i = 0; i <= data.Length - marker.Length; i++)
        {
            var match = true;
            for (var j = 0; j < marker.Length; j++)
            {
                if (data[i + j] != marker[j])
                {
                    match = false;
                    break;
                }
            }
            if (match) return true;
        }
        return false;
    }

    private static async Task<int> RunPdf(Options options)
    {
        using (var source = await OpenPdf(options.PdfPath, options.Password))
        {
            var totalPages = (int)source.Document.PageCount;
            if (totalPages <= 0)
            {
                throw new HostException("render_failed", "PDF 没有任何页面。");
            }

            var requested = new List<int>();
            if (options.RequestedPages.Count == 0)
            {
                for (var page = 1; page <= totalPages; page++) requested.Add(page);
            }
            else
            {
                requested.AddRange(options.RequestedPages);
            }

            if (requested.Count > options.Limits.MaxPages)
            {
                throw new HostException(
                    "too_large",
                    "本次请求 " + requested.Count + " 页，超过单次上限 " + options.Limits.MaxPages + " 页。请分批处理。");
            }

            _events.Ready("pdf", totalPages, "pdf", EngineLanguages);
            var ok = 0;
            var failed = 0;

            for (var index = 0; index < requested.Count; index++)
            {
                var pageNumber = requested[index];
                var pageClock = Stopwatch.StartNew();
                if (pageNumber < 1 || pageNumber > totalPages)
                {
                    failed++;
                    _events.Error(
                        pageNumber,
                        "page_out_of_range",
                        "第 " + pageNumber + " 页超出文档范围（共 " + totalPages + " 页）。",
                        pageClock.ElapsedMilliseconds);
                    continue;
                }
                try
                {
                    using (var page = source.Document.GetPage((uint)(pageNumber - 1)))
                    {
                        var bitmap = await RenderPdfPage(page, options.Limits, options.Limits.Dpi);
                        if (bitmap == null)
                        {
                            failed++;
                            _events.Error(
                                pageNumber,
                                "too_large",
                                "该页在当前 DPI 下像素数超过上限（" + options.Limits.MaxPixels + " 像素，最长边 " +
                                options.Limits.MaxDimension + "）。请降低 DPI 或分批处理。",
                                pageClock.ElapsedMilliseconds);
                            continue;
                        }
                        using (bitmap)
                        {
                            var outcome = await Recognize(bitmap, pageNumber, options.Limits.Dpi);
                            if (outcome == null)
                            {
                                failed++;
                                _events.Error(
                                    pageNumber,
                                    "ocr_failed",
                                    "该页没有识别出文字（页面可能为空白、手写或非文字内容）。",
                                    pageClock.ElapsedMilliseconds);
                                continue;
                            }
                            ok++;
                            _events.Page(pageNumber, index + 1, requested.Count, outcome.Width, outcome.Height, options.Limits.Dpi, false);
                            _events.Result(outcome, requested.Count, pageClock.ElapsedMilliseconds);
                        }
                    }
                }
                catch (HostException error)
                {
                    failed++;
                    _events.Error(pageNumber, error.Code, error.Message, pageClock.ElapsedMilliseconds);
                }
                catch (Exception ex)
                {
                    failed++;
                    _events.Error(
                        pageNumber,
                        "render_failed",
                        "第 " + pageNumber + " 页渲染或识别失败：" + ShortError(ex),
                        pageClock.ElapsedMilliseconds);
                }
            }

            _events.Done(requested.Count, ok, failed, false);
            return ExitCodeFor(ok, failed);
        }
    }

    private static async Task<SoftwareBitmap> RenderPdfPage(PdfPage page, Limits limits, int requestedDpi)
    {
        var widthDip = page.Size.Width;
        var heightDip = page.Size.Height;
        if (widthDip <= 0 || heightDip <= 0)
        {
            throw new HostException("render_failed", "该页尺寸无效，无法渲染。");
        }

        // Requested pixel size at the caller's DPI.
        var targetWidth = widthDip * requestedDpi / 96.0;
        var targetHeight = heightDip * requestedDpi / 96.0;

        // Never silently render below the requested DPI: a page that does not fit
        // the caller's resource limits is reported as too_large for that page, so
        // the user (or the service) can lower the DPI explicitly. Downscaling
        // behind their back would be a fake success.
        if (targetWidth * targetHeight > limits.MaxPixels ||
            targetWidth > limits.MaxDimension ||
            targetHeight > limits.MaxDimension)
        {
            return null;
        }

        // Windows.Data.Pdf maps DestinationWidth through the display rasterisation
        // scale (e.g. 1.4x at 140% scaling), so a value of N can produce N*1.4
        // pixels. Measure it once per process via one cheap render, then ask for
        // the exact pixel width we want so the caller's DPI is honoured exactly.
        var renderScale = GetRenderScale();
        if (renderScale <= 0)
        {
            var probeWidth = (uint)Math.Max(1, Math.Round(widthDip));
            using (var probeStream = new InMemoryRandomAccessStream())
            {
                var probeOptions = new PdfPageRenderOptions();
                probeOptions.DestinationWidth = probeWidth;
                await page.RenderToStreamAsync(probeStream, probeOptions);
                probeStream.Seek(0);
                var probeDecoder = await BitmapDecoder.CreateAsync(probeStream);
                if (probeDecoder.PixelWidth > 0 && probeWidth > 0)
                {
                    renderScale = (double)probeDecoder.PixelWidth / probeWidth;
                    StoreRenderScale(renderScale);
                }
                else
                {
                    renderScale = 1.0;
                    StoreRenderScale(1.0);
                }
            }
        }

        var destinationWidth = (uint)Math.Max(1, Math.Round(targetWidth / renderScale));
        using (var stream = new InMemoryRandomAccessStream())
        {
            var options = new PdfPageRenderOptions();
            options.DestinationWidth = destinationWidth;
            await page.RenderToStreamAsync(stream, options);
            stream.Seek(0);
            var decoder = await BitmapDecoder.CreateAsync(stream);
            if (decoder.PixelWidth > (uint)limits.MaxDimension || decoder.PixelHeight > (uint)limits.MaxDimension)
            {
                throw new HostException("too_large", "渲染结果超过最大边长限制。");
            }
            return await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied);
        }
    }

    private static double GetRenderScale()
    {
        lock (RenderScaleLock)
        {
            return _renderScale;
        }
    }

    private static void StoreRenderScale(double scale)
    {
        lock (RenderScaleLock)
        {
            _renderScale = scale;
        }
    }

    // ------------------------------------------------------------------ image

    private static IRandomAccessStream OpenReadStream(string path)
    {
        try
        {
            var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
            return file.AsRandomAccessStream();
        }
        catch (FileNotFoundException ex)
        {
            throw new HostException("render_failed", "找不到图片文件：路径不存在或不可访问。", ex);
        }
        catch (Exception ex)
        {
            throw new HostException("render_failed", "图片无法打开：" + ShortError(ex), ex);
        }
    }

    private static async Task<int> RunImage(Options options)
    {
        using (var stream = OpenReadStream(options.ImagePath))
        {
            BitmapDecoder decoder;
            try
            {
                decoder = await BitmapDecoder.CreateAsync(stream);
            }
            catch (Exception ex)
            {
                throw new HostException("render_failed", "图片无法解码（可能不是 PNG/JPEG 或文件已损坏）：" + ShortError(ex), ex);
            }

            var width = (uint)decoder.PixelWidth;
            var height = (uint)decoder.PixelHeight;
            if (width < 8 || height < 8)
            {
                throw new HostException("too_large", "图片尺寸过小或无效（" + width + "x" + height + "）。");
            }

            var transform = new BitmapTransform();
            var scale = 1.0;
            var area = (double)width * height;
            if (area > options.Limits.MaxPixels) scale = Math.Min(scale, Math.Sqrt(options.Limits.MaxPixels / area));
            scale = Math.Min(scale, (double)options.Limits.MaxDimension / width);
            scale = Math.Min(scale, (double)options.Limits.MaxDimension / height);
            var scaled = scale < 0.999;
            if (scaled)
            {
                transform.ScaledWidth = (uint)Math.Max(8, Math.Round(width * scale));
                transform.ScaledHeight = (uint)Math.Max(8, Math.Round(height * scale));
                transform.InterpolationMode = BitmapInterpolationMode.Fant;
            }

            SoftwareBitmap bitmap;
            try
            {
                bitmap = await decoder.GetSoftwareBitmapAsync(
                    BitmapPixelFormat.Bgra8,
                    BitmapAlphaMode.Premultiplied,
                    transform,
                    ExifOrientationMode.RespectExifOrientation,
                    ColorManagementMode.DoNotColorManage);
            }
            catch (Exception ex)
            {
                throw new HostException("render_failed", "图片无法转换为可识别位图：" + ShortError(ex), ex);
            }

            using (bitmap)
            {
                _events.Ready("image", 1, "image", EngineLanguages);
                var pageClock = Stopwatch.StartNew();
                var requestedPages = options.RequestedPages;
                if (requestedPages.Count > 0 && (requestedPages.Count != 1 || requestedPages[0] != 1))
                {
                    _events.Error(1, "page_out_of_range", "图片只有第 1 页。", pageClock.ElapsedMilliseconds);
                    _events.Done(1, 0, 1, false);
                    return 1;
                }
                var outcome = await Recognize(bitmap, 1, options.Limits.Dpi);
                if (outcome == null)
                {
                    _events.Error(1, "ocr_failed", "图片没有识别出文字（可能是空白、手写或非文字内容）。", pageClock.ElapsedMilliseconds);
                    _events.Done(1, 0, 1, false);
                    return 2;
                }
                _events.Page(1, 1, 1, outcome.Width, outcome.Height, options.Limits.Dpi, scaled);
                _events.Result(outcome, 1, pageClock.ElapsedMilliseconds);
                _events.Done(1, 1, 0, false);
                return 0;
            }
        }
    }

    // ------------------------------------------------------------------- ocr

    private static async Task<OcrPageOutcome> Recognize(SoftwareBitmap bitmap, int pageNumber, int dpi)
    {
        // Run every installed engine the caller asked for and keep the candidate
        // that looks most like real text. Windows OCR exposes no confidence score,
        // so selection uses script statistics instead:
        //   * CJK characters weigh slightly more (dense information),
        //   * spaces *inside* Latin words ("N ote s") are penalised, which is the
        //     typical artefact of a Chinese engine applied to an English page,
        //   * ties prefer more lines.
        OcrPageOutcome best = null;
        Exception lastError = null;
        foreach (var engine in Engines)
        {
            try
            {
                var result = await engine.RecognizeAsync(bitmap);
                var outcome = new OcrPageOutcome();
                outcome.Page = pageNumber;
                outcome.Width = (uint)bitmap.PixelWidth;
                outcome.Height = (uint)bitmap.PixelHeight;
                outcome.Dpi = dpi;
                outcome.Language = engine.RecognizerLanguage.LanguageTag;
                if (result != null && result.Lines != null)
                {
                    var texts = new List<string>();
                    foreach (var line in result.Lines)
                    {
                        var info = new OcrLineInfo();
                        info.Text = line.Text ?? "";
                        info.X = double.MaxValue;
                        info.Y = double.MaxValue;
                        var maxX = double.MinValue;
                        var maxY = double.MinValue;
                        foreach (var word in line.Words)
                        {
                            var rect = word.BoundingRect;
                            if (rect.X < info.X) info.X = rect.X;
                            if (rect.Y < info.Y) info.Y = rect.Y;
                            if (rect.X + rect.Width > maxX) maxX = rect.X + rect.Width;
                            if (rect.Y + rect.Height > maxY) maxY = rect.Y + rect.Height;
                        }
                        if (info.X == double.MaxValue)
                        {
                            info.X = 0;
                            info.Y = 0;
                            info.Width = 0;
                            info.Height = 0;
                        }
                        else
                        {
                            info.Width = maxX - info.X;
                            info.Height = maxY - info.Y;
                        }
                        outcome.Lines.Add(info);
                        texts.Add(info.Text);
                    }
                    outcome.Text = string.Join("\n", texts.ToArray());
                    outcome.Score = ScoreText(outcome.Text);
                }
                if (best == null || outcome.Score > best.Score ||
                    (Math.Abs(outcome.Score - best.Score) < 0.0001 && outcome.Lines.Count > best.Lines.Count))
                {
                    best = outcome;
                }
            }
            catch (Exception ex)
            {
                lastError = ex;
                _err.WriteLine("[ocr_host] OCR failed with " + engine.RecognizerLanguage.LanguageTag + ": " + ShortError(ex));
            }
        }

        if (best == null && lastError != null)
        {
            throw new HostException("ocr_failed", "OCR 引擎执行失败：" + ShortError(lastError), lastError);
        }
        if (best == null || best.Text.Trim().Length == 0)
        {
            return null;
        }
        return best;
    }

    private static double ScoreText(string text)
    {
        var score = 0.0;
        var intraWordSpaces = 0;
        for (var i = 0; i < text.Length; i++)
        {
            var c = text[i];
            if (IsCjk(c)) score += 1.2;              // dense, unambiguous characters
            else if (char.IsLetterOrDigit(c)) score += 1.0;
            else if (c == ' ')
            {
                // "N ote s" style spacing is a strong hint that the wrong engine
                // (or the wrong script) produced this candidate.
                if (i > 0 && i + 1 < text.Length &&
                    IsAsciiLetter(text[i - 1]) && IsAsciiLetter(text[i + 1]))
                {
                    intraWordSpaces++;
                }
                else
                {
                    score += 0.05;
                }
            }
        }
        return score - 3.0 * intraWordSpaces;
    }

    private static bool IsAsciiLetter(char c)
    {
        return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
    }

    private static bool IsCjk(char c)
    {
        return (c >= '\u3400' && c <= '\u4DBF') ||
               (c >= '\u4E00' && c <= '\u9FFF') ||
               (c >= '\uF900' && c <= '\uFAFF');
    }

    private static int ExitCodeFor(int ok, int failed)
    {
        if (failed == 0 && ok > 0) return 0;
        if (ok > 0) return 1;
        return 2;
    }
}
