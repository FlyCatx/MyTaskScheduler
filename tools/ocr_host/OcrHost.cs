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
using System.Text.RegularExpressions;
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
    public const string Version = "1.1.0";
    public const string EngineName = "Windows.Media.Ocr";

    /// <summary>
    /// Version of the *post-processing pipeline* (heuristic scoring, mixed-line
    /// candidate selection, row grouping, low-quality retry). It is part of the
    /// runtime contract and must be part of the OCR cache key: an old cached page
    /// must never hide a new algorithm. Bump it whenever the emitted text for the
    /// same pixels can change.
    /// </summary>
    public const string PipelineVersion = "heuristic-2+rows-1+enhance-1";

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
    /// <summary>
    /// Pick the best candidate per line/region instead of one engine for the page.
    /// OFF by default: on the task-05 corpus this is neutral (mixed/English pages
    /// can get a worse line), so it stays an opt-in experiment (`--mixed-lines`)
    /// with its own measured ablation rather than a silent default change.
    /// </summary>
    public bool MixedLines = false;
    /// <summary>Retry a low-quality page at a higher DPI / other rotation (bounded).</summary>
    public bool Enhance = true;
    public int EnhanceRetries = 1;
    public bool SelfTest = false;
    public readonly List<int> RequestedPages = new List<int>();
}

internal sealed class LangInfo
{
    public string Tag = "";
    public string DisplayName = "";
    public string NativeName = "";
    public bool Recognizer = true;
}

internal sealed class OcrWordInfo
{
    public string Text = "";
    public double X;
    public double Y;
    public double Width;
    public double Height;
}

internal sealed class OcrLineInfo
{
    public string Text = "";
    public double X;
    public double Y;
    public double Width;
    public double Height;
    /// <summary>Word boxes, kept so rows can be rebuilt by y-overlap later.</summary>
    public readonly List<OcrWordInfo> Words = new List<OcrWordInfo>();
    /// <summary>"region" when the text was chosen per line from another engine.</summary>
    public string Source = "page";
    /// <summary>Language tag of the engine that produced this line's text.</summary>
    public string Language = "";
}

internal sealed class OcrCellInfo
{
    public string Text = "";
    public double X;
    public double Y;
    public double Width;
    public double Height;
}

internal sealed class OcrRowInfo
{
    public double Y;
    public double Height;
    public string Text = "";
    public readonly List<OcrCellInfo> Cells = new List<OcrCellInfo>();
}

internal sealed class OcrFieldCheck
{
    public string Kind = "";        // date | time | minutes
    public string Raw = "";         // exactly as recognised, never rewritten
    public string Normalised = "";  // comparison form (ISO date / H:MM / number)
    public bool Valid;
    public bool NeedsReview;
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
    public double Quality;              // score per valid character (0..~1.2)
    public int ValidChars;
    public int SpaceFragments;
    public int SuspiciousChars;
    public int Attempts = 1;
    public bool Retried;
    /// <summary>OCR (not render) time per attempt, for honest cost reporting.</summary>
    public readonly List<long> AttemptElapsedMs = new List<long>();
    public string WholePageEngine = "";
    public bool LineSelectionApplied;
    public int ChangedLines;
    /// <summary>"lines" (engine reading order) or "rows" (table row order).</summary>
    public string TextOrder = "lines";
    public readonly List<string> EnginesUsed = new List<string>();
    public readonly List<OcrRowInfo> Rows = new List<OcrRowInfo>();
    public readonly List<OcrFieldCheck> Fields = new List<OcrFieldCheck>();
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
        sb.Append(",\"pipelineVersion\":").Append(Json.Str(HostInfo.PipelineVersion));
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
        sb.Append(",\"pipelineVersion\":").Append(Json.Str(HostInfo.PipelineVersion));
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
        sb.Append(",\"pipelineVersion\":").Append(Json.Str(HostInfo.PipelineVersion));
        sb.Append(",\"dpi\":").Append(Json.Int(outcome.Dpi));
        sb.Append(",\"width\":").Append(Json.Int(outcome.Width));
        sb.Append(",\"height\":").Append(Json.Int(outcome.Height));
        sb.Append(",\"elapsedMs\":").Append(Json.Int(elapsedMs));
        // Two different numbers, never conflated:
        //   * score/quality are heuristic text statistics computed by this host,
        //   * confidence is the engine's own value -- Windows.Media.Ocr exposes
        //     none, so it stays null instead of an invented number.
        sb.Append(",\"score\":").Append(Json.Num(outcome.Score));
        sb.Append(",\"quality\":").Append(Json.Num(outcome.Quality));
        sb.Append(",\"confidence\":null");
        sb.Append(",\"attempts\":").Append(Json.Int(outcome.Attempts));
        sb.Append(",\"retried\":").Append(outcome.Retried ? "true" : "false");
        sb.Append(",\"attemptElapsedMs\":[");
        for (var a = 0; a < outcome.AttemptElapsedMs.Count; a++)
        {
            if (a > 0) sb.Append(',');
            sb.Append(Json.Int(outcome.AttemptElapsedMs[a]));
        }
        sb.Append(']');
        sb.Append(",\"wholePageEngine\":").Append(Json.Str(outcome.WholePageEngine));
        sb.Append(",\"textOrder\":").Append(Json.Str(outcome.TextOrder));
        sb.Append(",\"lineSelection\":{\"applied\":").Append(outcome.LineSelectionApplied ? "true" : "false");
        sb.Append(",\"changedLines\":").Append(Json.Int(outcome.ChangedLines));
        sb.Append(",\"enginesUsed\":[");
        for (var e = 0; e < outcome.EnginesUsed.Count; e++)
        {
            if (e > 0) sb.Append(',');
            Json.AppendStr(sb, outcome.EnginesUsed[e]);
        }
        sb.Append("]}");
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
            sb.Append("],\"source\":").Append(Json.Str(line.Source));
            sb.Append(",\"engine\":").Append(Json.Str(line.Language));
            sb.Append('}');
        }
        sb.Append("],\"rows\":[");
        for (var r = 0; r < outcome.Rows.Count; r++)
        {
            var row = outcome.Rows[r];
            if (r > 0) sb.Append(',');
            sb.Append("{\"y\":").Append(Json.Num(row.Y));
            sb.Append(",\"height\":").Append(Json.Num(row.Height));
            sb.Append(",\"text\":");
            Json.AppendStr(sb, row.Text);
            sb.Append(",\"cells\":[");
            for (var c = 0; c < row.Cells.Count; c++)
            {
                var cell = row.Cells[c];
                if (c > 0) sb.Append(',');
                sb.Append("{\"text\":");
                Json.AppendStr(sb, cell.Text);
                sb.Append(",\"bbox\":[");
                sb.Append(Json.Num(cell.X)).Append(',');
                sb.Append(Json.Num(cell.Y)).Append(',');
                sb.Append(Json.Num(cell.Width)).Append(',');
                sb.Append(Json.Num(cell.Height));
                sb.Append("]}");
            }
            sb.Append("]}");
        }
        sb.Append("],\"reviewFields\":[");
        for (var f = 0; f < outcome.Fields.Count; f++)
        {
            var field = outcome.Fields[f];
            if (f > 0) sb.Append(',');
            sb.Append("{\"kind\":").Append(Json.Str(field.Kind));
            sb.Append(",\"raw\":").Append(Json.Str(field.Raw));
            sb.Append(",\"normalised\":").Append(Json.Str(field.Normalised));
            sb.Append(",\"valid\":").Append(field.Valid ? "true" : "false");
            sb.Append(",\"needsReview\":").Append(field.NeedsReview ? "true" : "false");
            sb.Append('}');
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
        if (options.Mode == "self-test")
        {
            return RunSelfTest();
        }

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
                case "--no-mixed-lines":
                    options.MixedLines = false;
                    break;
                case "--mixed-lines":
                    options.MixedLines = true;
                    break;
                case "--no-enhance":
                    options.Enhance = false;
                    break;
                case "--enhance-retries":
                    options.EnhanceRetries = ParseInt(RequireValue(args, ref i, "--enhance-retries"), "--enhance-retries");
                    break;
                case "--self-test":
                    options.SelfTest = true;
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
        if (options.SelfTest)
        {
            if (options.Probe || options.Info || options.PdfPath.Length > 0 ||
                options.ImagePath.Length > 0 || options.PagesSpec.Length > 0)
            {
                throw new UsageException("--self-test 不能与其它模式同时使用。");
            }
            options.Mode = "self-test";
        }
        else if (options.Probe)
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
        if (options.EnhanceRetries < 0 || options.EnhanceRetries > 3)
        {
            throw new UsageException("--enhance-retries 必须在 0 到 3 之间（收到 " + options.EnhanceRetries + "）。");
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
        _err.WriteLine("  ocr_host.exe --self-test");
        _err.WriteLine("  通用: [--max-pixels N] [--max-dimension N] [--max-pages N] [--watch-stdin]");
        _err.WriteLine("        [--no-mixed-lines] [--mixed-lines] [--no-enhance] [--enhance-retries N]");
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
                            var attemptClock = Stopwatch.StartNew();
                            var outcome = await Recognize(bitmap, pageNumber, options.Limits.Dpi, options.MixedLines);
                            attemptClock.Stop();
                            var attemptElapsed = new List<long>();
                            attemptElapsed.Add(attemptClock.ElapsedMilliseconds);
                            // One bounded retry for a page that looks bad. A higher DPI can
                            // only add detail that exists in the PDF; a page whose embedded
                            // bitmap is already low resolution may not improve (measured in
                            // docs/task05). Cancellation is the same as the job: the stdin
                            // watchdog still terminates the process.
                            if (outcome != null && options.Enhance && options.EnhanceRetries > 0 &&
                                IsLowQuality(outcome) && options.Limits.Dpi < Limits.MaxDpi)
                            {
                                var retryDpi = Math.Min(300, options.Limits.Dpi * 2);
                                if (retryDpi > options.Limits.Dpi)
                                {
                                    try
                                    {
                                        var retryBitmap = await RenderPdfPage(page, options.Limits, retryDpi);
                                        if (retryBitmap == null)
                                        {
                                            outcome.Attempts = 2;
                                            outcome.Retried = true;
                                        }
                                        else
                                        {
                                            using (retryBitmap)
                                            {
                                                attemptClock.Restart();
                                                var retryOutcome = await Recognize(
                                                    retryBitmap, pageNumber, retryDpi, options.MixedLines);
                                                attemptClock.Stop();
                                                attemptElapsed.Add(attemptClock.ElapsedMilliseconds);
                                                if (IsBetter(retryOutcome, outcome))
                                                {
                                                    retryOutcome.Attempts = outcome.Attempts + 1;
                                                    retryOutcome.Retried = true;
                                                    retryOutcome.AttemptElapsedMs.AddRange(attemptElapsed);
                                                    outcome = retryOutcome;
                                                }
                                                else
                                                {
                                                    outcome.Attempts = 2;
                                                    outcome.Retried = true;
                                                    outcome.AttemptElapsedMs.AddRange(attemptElapsed);
                                                }
                                            }
                                        }
                                    }
                                    catch (Exception retryError)
                                    {
                                        _err.WriteLine("[ocr_host] retry failed for page " + pageNumber +
                                                       ": " + ShortError(retryError));
                                    }
                                }
                            }
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
                            if (outcome.AttemptElapsedMs.Count == 0)
                            {
                                outcome.AttemptElapsedMs.AddRange(attemptElapsed);
                            }
                            ok++;
                            _events.Page(pageNumber, index + 1, requested.Count, outcome.Width, outcome.Height, outcome.Dpi, false);
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

            _events.Ready("image", 1, "image", EngineLanguages);
            var pageClock = Stopwatch.StartNew();
            var requestedPages = options.RequestedPages;
            if (requestedPages.Count > 0 && (requestedPages.Count != 1 || requestedPages[0] != 1))
            {
                _events.Error(1, "page_out_of_range", "图片只有第 1 页。", pageClock.ElapsedMilliseconds);
                _events.Done(1, 0, 1, false);
                return 1;
            }

            // Orientation retry: a photo taken sideways produces no usable text
            // at 0 degrees. Only low-quality pages pay for the extra attempts,
            // which are bounded by --enhance-retries (0..3 => at most 4 passes).
            OcrPageOutcome best = null;
            var bestScaled = false;
            var attempts = 0;
            var attemptElapsedAll = new List<long>();
            var rotations = new List<BitmapRotation>();
            rotations.Add(BitmapRotation.None);
            if (options.Enhance && options.EnhanceRetries > 0)
            {
                rotations.Add(BitmapRotation.Clockwise90Degrees);
                rotations.Add(BitmapRotation.Clockwise180Degrees);
                rotations.Add(BitmapRotation.Clockwise270Degrees);
            }

            foreach (var rotation in rotations)
            {
                attempts++;
                DecodedImage decoded;
                try
                {
                    decoded = await DecodeImage(stream, options.Limits, rotation);
                }
                catch (Exception ex)
                {
                    _err.WriteLine("[ocr_host] image decode attempt " + attempts + " failed: " + ShortError(ex));
                    continue;
                }
                try
                {
                    using (decoded.Bitmap)
                    {
                        var attemptClock = Stopwatch.StartNew();
                        var outcome = await Recognize(decoded.Bitmap, 1, options.Limits.Dpi, options.MixedLines);
                        attemptClock.Stop();
                        attemptElapsedAll.Add(attemptClock.ElapsedMilliseconds);
                        if (outcome != null && IsBetter(outcome, best))
                        {
                            best = outcome;
                            bestScaled = decoded.Scaled;
                        }
                    }
                }
                catch (Exception ex)
                {
                    _err.WriteLine("[ocr_host] image OCR attempt " + attempts + " failed: " + ShortError(ex));
                    continue;
                }
                // Stop early only when the *first* attempt is already healthy: a
                // suspicious page evaluates every allowed rotation, because a
                // wrongly rotated attempt can still yield a few clean-looking
                // glyphs and must not end the search.
                if (attempts == 1 && best != null && IsWellOriented(best)) break;
            }

            if (best == null)
            {
                _events.Error(1, "ocr_failed", "图片没有识别出文字（可能是空白、手写或非文字内容）。", pageClock.ElapsedMilliseconds);
                _events.Done(1, 0, 1, false);
                return 2;
            }
            best.Attempts = attempts;
            best.Retried = attempts > 1;
            best.AttemptElapsedMs.AddRange(attemptElapsedAll);
            _events.Page(1, 1, 1, best.Width, best.Height, best.Dpi, bestScaled);
            _events.Result(best, 1, pageClock.ElapsedMilliseconds);
            _events.Done(1, 1, 0, false);
            return 0;
        }
    }

    /// <summary>Result of one decoded image attempt (rotation + scaling).</summary>
    private sealed class DecodedImage
    {
        public SoftwareBitmap Bitmap;
        public bool Scaled;
    }

    /// <summary>Decodes the image with the exact scaling limits and an optional
    /// 90-degree rotation used by the orientation retry.</summary>
    private static async Task<DecodedImage> DecodeImage(
        IRandomAccessStream stream, Limits limits, BitmapRotation rotation)
    {
        stream.Seek(0);
        var decoder = await BitmapDecoder.CreateAsync(stream);
        var width = (uint)decoder.PixelWidth;
        var height = (uint)decoder.PixelHeight;
        if (width < 8 || height < 8)
        {
            throw new HostException("too_large", "图片尺寸过小或无效（" + width + "x" + height + "）。");
        }
        var transform = new BitmapTransform();
        var scale = 1.0;
        var area = (double)width * height;
        if (area > limits.MaxPixels) scale = Math.Min(scale, Math.Sqrt(limits.MaxPixels / area));
        scale = Math.Min(scale, (double)limits.MaxDimension / width);
        scale = Math.Min(scale, (double)limits.MaxDimension / height);
        var decoded = new DecodedImage();
        decoded.Scaled = scale < 0.999;
        if (decoded.Scaled)
        {
            transform.ScaledWidth = (uint)Math.Max(8, Math.Round(width * scale));
            transform.ScaledHeight = (uint)Math.Max(8, Math.Round(height * scale));
            transform.InterpolationMode = BitmapInterpolationMode.Fant;
        }
        transform.Rotation = rotation;
        try
        {
            decoded.Bitmap = await decoder.GetSoftwareBitmapAsync(
                BitmapPixelFormat.Bgra8,
                BitmapAlphaMode.Premultiplied,
                transform,
                ExifOrientationMode.RespectExifOrientation,
                ColorManagementMode.DoNotColorManage);
            return decoded;
        }
        catch (Exception ex)
        {
            throw new HostException("render_failed", "图片无法转换为可识别位图：" + ShortError(ex), ex);
        }
    }

    // ------------------------------------------------------------------- ocr

    private static async Task<OcrPageOutcome> Recognize(
        SoftwareBitmap bitmap, int pageNumber, int dpi, bool mixedLines)
    {
        // Run every installed engine the caller asked for, then pick candidates:
        //   * whole-page: the single engine with the best heuristic text score,
        //   * per-line (default when >1 engine): each line region takes the best
        //     candidate text from any engine, keeping page/line/bbox provenance.
        // Windows.Media.Ocr exposes no confidence score, so selection uses text
        // statistics only (see ScoreText) and the engine confidence stays null.
        var candidates = new List<OcrPageOutcome>();
        Exception lastError = null;
        foreach (var engine in Engines)
        {
            try
            {
                var outcome = await RecognizeWithEngine(engine, bitmap, pageNumber, dpi);
                if (outcome != null) candidates.Add(outcome);
            }
            catch (Exception ex)
            {
                lastError = ex;
                _err.WriteLine("[ocr_host] OCR failed with " + engine.RecognizerLanguage.LanguageTag + ": " + ShortError(ex));
            }
        }

        if (candidates.Count == 0)
        {
            if (lastError != null)
            {
                throw new HostException("ocr_failed", "OCR 引擎执行失败：" + ShortError(lastError), lastError);
            }
            return null;
        }

        OcrPageOutcome best = null;
        foreach (var candidate in candidates)
        {
            if (best == null || candidate.Score > best.Score ||
                (Math.Abs(candidate.Score - best.Score) < 0.0001 && candidate.Lines.Count > best.Lines.Count))
            {
                best = candidate;
            }
        }
        if (best == null) return null;

        best.WholePageEngine = best.Language;
        AddEngineUsed(best, best.Language);

        if (mixedLines && candidates.Count > 1)
        {
            ApplyLineSelection(best, candidates);
        }
        if (best.Text.Trim().Length == 0)
        {
            return null;
        }

        BuildRows(best);
        if (ShouldUseRowText(best))
        {
            var rowTexts = new List<string>();
            foreach (var row in best.Rows) rowTexts.Add(row.Text);
            best.Text = string.Join("\n", rowTexts.ToArray());
            best.TextOrder = "rows";
            int rowValid;
            int rowFragments;
            int rowSuspicious;
            best.Score = ScoreText(best.Text, out rowValid, out rowFragments, out rowSuspicious);
            best.ValidChars = rowValid;
            best.SpaceFragments = rowFragments;
            best.SuspiciousChars = rowSuspicious;
            best.Quality = QualityFrom(best.Score, rowValid);
        }
        BuildFields(best);
        return best;
    }

    private static async Task<OcrPageOutcome> RecognizeWithEngine(
        OcrEngine engine, SoftwareBitmap bitmap, int pageNumber, int dpi)
    {
        var result = await engine.RecognizeAsync(bitmap);
        var outcome = new OcrPageOutcome();
        outcome.Page = pageNumber;
        outcome.Width = (uint)bitmap.PixelWidth;
        outcome.Height = (uint)bitmap.PixelHeight;
        outcome.Dpi = dpi;
        outcome.Language = engine.RecognizerLanguage.LanguageTag;
        if (result == null || result.Lines == null)
        {
            return outcome;
        }

        var texts = new List<string>();
        foreach (var line in result.Lines)
        {
            var info = new OcrLineInfo();
            info.Text = SanitizeText(line.Text ?? "");
            info.Language = outcome.Language;
            info.X = double.MaxValue;
            info.Y = double.MaxValue;
            var maxX = double.MinValue;
            var maxY = double.MinValue;
            foreach (var word in line.Words)
            {
                var rect = word.BoundingRect;
                var wordInfo = new OcrWordInfo();
                wordInfo.Text = SanitizeText(word.Text ?? "");
                wordInfo.X = rect.X;
                wordInfo.Y = rect.Y;
                wordInfo.Width = rect.Width;
                wordInfo.Height = rect.Height;
                info.Words.Add(wordInfo);
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
        int valid;
        int fragments;
        int suspicious;
        outcome.Score = ScoreText(outcome.Text, out valid, out fragments, out suspicious);
        outcome.ValidChars = valid;
        outcome.SpaceFragments = fragments;
        outcome.SuspiciousChars = suspicious;
        outcome.Quality = QualityFrom(outcome.Score, valid);
        return outcome;
    }

    /// <summary>
    /// Merge line candidates from every engine: for each line region of the
    /// whole-page winner, use the highest-scoring text among engines whose line
    /// box overlaps that region; keep the primary reading order and geometry.
    /// Lines only present in another engine are appended in y order. This never
    /// invents text and never drops a region silently: every chosen line keeps
    /// its engine tag and bbox in the result event.
    /// </summary>
    private static void ApplyLineSelection(OcrPageOutcome primary, List<OcrPageOutcome> candidates)
    {
        var changed = 0;
        var selected = new List<OcrLineInfo>();
        foreach (var primaryLine in primary.Lines)
        {
            var bestLine = primaryLine;
            var bestQuality = LineQuality(primaryLine.Text);
            foreach (var candidate in candidates)
            {
                if (ReferenceEquals(candidate, primary)) continue;
                // Whole-page gate: an engine that is clearly worse for the page
                // as a whole must not win single lines just because a line is
                // longer (that was measured as a regression on pure-English and
                // pure-Chinese pages).
                if (candidate.Quality < primary.Quality - 0.15) continue;
                var match = FindOverlappingLine(candidate.Lines, primaryLine);
                if (match == null) continue;
                // Compare quality per character, not the raw sum: a longer but
                // messier candidate line must not beat a short clean one.
                var quality = LineQuality(match.Text);
                if (quality > bestQuality + 0.02)
                {
                    bestQuality = quality;
                    bestLine = match;
                }
            }
            var chosen = new OcrLineInfo();
            chosen.Text = bestLine.Text;
            chosen.X = bestLine.X;
            chosen.Y = bestLine.Y;
            chosen.Width = bestLine.Width;
            chosen.Height = bestLine.Height;
            chosen.Language = bestLine.Language;
            chosen.Source = ReferenceEquals(bestLine, primaryLine) ? "page" : "region";
            chosen.Words.AddRange(bestLine.Words);
            if (chosen.Text != primaryLine.Text)
            {
                changed++;
                AddEngineUsed(primary, chosen.Language);
            }
            selected.Add(chosen);
        }

        // Deliberately no "append lines only the other engine saw": such lines
        // have no primary anchor, so keeping them would duplicate or inject
        // garbage (measured on the table samples). Region selection replaces
        // line text only, never adds regions.
        primary.Lines.Clear();
        primary.Lines.AddRange(selected);
        var texts = new List<string>();
        foreach (var line in primary.Lines) texts.Add(line.Text);
        primary.Text = string.Join("\n", texts.ToArray());
        int valid;
        int fragments;
        int suspicious;
        primary.Score = ScoreText(primary.Text, out valid, out fragments, out suspicious);
        primary.ValidChars = valid;
        primary.SpaceFragments = fragments;
        primary.SuspiciousChars = suspicious;
        primary.Quality = QualityFrom(primary.Score, valid);
        primary.LineSelectionApplied = changed > 0;
        primary.ChangedLines = changed;
    }

    private static OcrLineInfo FindOverlappingLine(List<OcrLineInfo> lines, OcrLineInfo target)
    {
        OcrLineInfo best = null;
        var bestScore = double.MinValue;
        foreach (var line in lines)
        {
            if (line.Text.Trim().Length == 0 || !LineOverlaps(line, target)) continue;
            var score = ScoreText(line.Text);
            if (score > bestScore)
            {
                bestScore = score;
                best = line;
            }
        }
        return best;
    }

    private static bool LineOverlaps(OcrLineInfo a, OcrLineInfo b)
    {
        var aCenter = a.Y + a.Height / 2.0;
        var bCenter = b.Y + b.Height / 2.0;
        var maxHeight = Math.Max(Math.Max(a.Height, b.Height), 1.0);
        if (Math.Abs(aCenter - bCenter) > maxHeight * 0.75) return false;
        var aLeft = a.X;
        var aRight = a.X + a.Width;
        var bLeft = b.X;
        var bRight = b.X + b.Width;
        var overlap = Math.Min(aRight, bRight) - Math.Max(aLeft, bLeft);
        var width = Math.Max(1.0, Math.Min(a.Width, b.Width));
        return overlap > width * 0.25;
    }

    private static void AddEngineUsed(OcrPageOutcome outcome, string language)
    {
        if (language == null || language.Length == 0) return;
        foreach (var existing in outcome.EnginesUsed)
        {
            if (existing == language) return;
        }
        outcome.EnginesUsed.Add(language);
    }

    /// <summary>
    /// Word boxes -> table rows, grouped by vertical centre/overlap. Engine line
    /// order is *not* trusted here: words read correctly but assigned to the
    /// wrong engine line (common in tables) are regrouped by y, then each row's
    /// cells are ordered by x. The result event carries rows[] with cell bboxes;
    /// the plain text field keeps the engine reading order for compatibility.
    /// </summary>
    private static void BuildRows(OcrPageOutcome outcome)
    {
        outcome.Rows.Clear();
        var words = new List<OcrWordInfo>();
        foreach (var line in outcome.Lines)
        {
            foreach (var word in line.Words)
            {
                if (word.Text != null && word.Text.Trim().Length > 0) words.Add(word);
            }
        }
        if (words.Count == 0) return;

        var heights = new List<double>();
        foreach (var word in words) heights.Add(Math.Max(1.0, word.Height));
        heights.Sort();
        var medianHeight = heights[heights.Count / 2];
        var tolerance = Math.Max(6.0, medianHeight * 0.55);
        var mergeGap = Math.Max(4.0, medianHeight * 0.45);

        var ordered = new List<OcrWordInfo>(words);
        ordered.Sort(delegate(OcrWordInfo a, OcrWordInfo b)
        {
            var ay = a.Y + a.Height / 2.0;
            var by = b.Y + b.Height / 2.0;
            if (Math.Abs(ay - by) > tolerance) return ay.CompareTo(by);
            return a.X.CompareTo(b.X);
        });

        var rowWords = new List<List<OcrWordInfo>>();
        var rowCenters = new List<double>();
        foreach (var word in ordered)
        {
            var center = word.Y + word.Height / 2.0;
            var placed = false;
            for (var r = rowWords.Count - 1; r >= 0 && r >= rowWords.Count - 4; r--)
            {
                var rowTolerance = Math.Max(tolerance, rowWords[r][0].Height * 0.6);
                if (Math.Abs(rowCenters[r] - center) <= rowTolerance)
                {
                    rowWords[r].Add(word);
                    rowCenters[r] = (rowCenters[r] * (rowWords[r].Count - 1) + center) / rowWords[r].Count;
                    placed = true;
                    break;
                }
            }
            if (!placed)
            {
                rowWords.Add(new List<OcrWordInfo>());
                rowCenters.Add(center);
                rowWords[rowWords.Count - 1].Add(word);
            }
        }

        var sortedRows = new List<OcrRowInfo>();
        for (var r = 0; r < rowWords.Count; r++)
        {
            var row = new OcrRowInfo();
            row.Y = double.MaxValue;
            var maxBottom = double.MinValue;
            var cells = new List<OcrCellInfo>();
            OcrCellInfo current = null;
            var wordsInRow = rowWords[r];
            wordsInRow.Sort(delegate(OcrWordInfo a, OcrWordInfo b) { return a.X.CompareTo(b.X); });
            foreach (var word in wordsInRow)
            {
                if (word.Y < row.Y) row.Y = word.Y;
                var bottom = word.Y + word.Height;
                if (bottom > maxBottom) maxBottom = bottom;
                var gap = current == null ? double.MaxValue : word.X - (current.X + current.Width);
                if (current != null && gap <= mergeGap)
                {
                    var joinSpace = gap > medianHeight * 0.18 ? " " : "";
                    current.Text = current.Text + joinSpace + word.Text;
                    current.Width = (word.X + word.Width) - current.X;
                    if (word.Height > current.Height) current.Height = word.Height;
                }
                else
                {
                    current = new OcrCellInfo();
                    current.Text = word.Text;
                    current.X = word.X;
                    current.Y = word.Y;
                    current.Width = word.Width;
                    current.Height = word.Height;
                    cells.Add(current);
                }
            }
            row.Height = Math.Max(1.0, maxBottom - row.Y);
            var cellTexts = new List<string>();
            foreach (var cell in cells) cellTexts.Add(cell.Text);
            row.Text = string.Join(" ", cellTexts.ToArray());
            row.Cells.AddRange(cells);
            sortedRows.Add(row);
        }
        sortedRows.Sort(delegate(OcrRowInfo a, OcrRowInfo b) { return a.Y.CompareTo(b.Y); });
        outcome.Rows.AddRange(sortedRows);
    }

    /// <summary>
    /// Date / time / minutes / hours format checks. The recognised string is kept
    /// verbatim in Raw; Normalised is only a comparison form. Anything the engine
    /// returned stays visible to the user; invalid values are marked (valid=false)
    /// and every extracted field is marked needsReview because Windows OCR has no
    /// confidence value to trust.
    /// </summary>
    private static void BuildFields(OcrPageOutcome outcome)
    {
        outcome.Fields.Clear();
        var compact = new StringBuilder();
        foreach (var c in outcome.Text)
        {
            if (!char.IsWhiteSpace(c)) compact.Append(c);
        }
        var text = compact.ToString();
        var seen = new HashSet<string>(StringComparer.Ordinal);

        foreach (Match match in Regex.Matches(text, @"(\d{4})[-/年](\d{1,2})[-/月](\d{1,2})日?"))
        {
            int year = 0;
            int month = 0;
            int day = 0;
            bool parsed = int.TryParse(match.Groups[1].Value, NumberStyles.Integer, CultureInfo.InvariantCulture, out year);
            parsed = parsed && int.TryParse(match.Groups[2].Value, NumberStyles.Integer, CultureInfo.InvariantCulture, out month);
            parsed = parsed && int.TryParse(match.Groups[3].Value, NumberStyles.Integer, CultureInfo.InvariantCulture, out day);
            var valid = parsed && IsValidDate(year, month, day);
            var normalised = valid
                ? year.ToString("0000", CultureInfo.InvariantCulture) + "-" +
                  month.ToString("00", CultureInfo.InvariantCulture) + "-" +
                  day.ToString("00", CultureInfo.InvariantCulture)
                : "";
            AddField(outcome, seen, "date", match.Value, normalised, valid);
        }

        foreach (Match match in Regex.Matches(text, @"(\d{1,2})[:：](\d{2})"))
        {
            int hour = 0;
            int minute = 0;
            bool parsed = int.TryParse(match.Groups[1].Value, NumberStyles.Integer, CultureInfo.InvariantCulture, out hour);
            parsed = parsed && int.TryParse(match.Groups[2].Value, NumberStyles.Integer, CultureInfo.InvariantCulture, out minute);
            var valid = parsed && hour >= 0 && hour <= 23 && minute >= 0 && minute <= 59;
            var normalised = valid
                ? hour.ToString(CultureInfo.InvariantCulture) + ":" + minute.ToString("00", CultureInfo.InvariantCulture)
                : "";
            AddField(outcome, seen, "time", match.Value, normalised, valid);
        }

        foreach (Match match in Regex.Matches(text, @"(\d{1,5})(?:分钟|minutes?|min)"))
        {
            int minutes;
            var valid = int.TryParse(match.Groups[1].Value, NumberStyles.Integer, CultureInfo.InvariantCulture, out minutes) &&
                        minutes > 0 && minutes <= 1440;
            AddField(outcome, seen, "minutes", match.Value,
                valid ? minutes.ToString(CultureInfo.InvariantCulture) : "", valid);
        }

        // "分钟：150" / "Minutes: 150" (the number follows the unit label).
        foreach (Match match in Regex.Matches(text, @"(?:分钟|minutes?|min)[:：]?(\d{1,5})"))
        {
            int minutes;
            var valid = int.TryParse(match.Groups[1].Value, NumberStyles.Integer, CultureInfo.InvariantCulture, out minutes) &&
                        minutes > 0 && minutes <= 1440;
            AddField(outcome, seen, "minutes", match.Value,
                valid ? minutes.ToString(CultureInfo.InvariantCulture) : "", valid);
        }

        foreach (Match match in Regex.Matches(text, @"(\d+(?:\.\d+)?)(?:小时|hours?|hrs?)"))
        {
            double hours;
            var valid = double.TryParse(match.Groups[1].Value, NumberStyles.Float, CultureInfo.InvariantCulture, out hours) &&
                        hours > 0 && hours <= 24;
            AddField(outcome, seen, "hours", match.Value,
                valid ? hours.ToString(CultureInfo.InvariantCulture) : "", valid);
        }
    }

    private static void AddField(
        OcrPageOutcome outcome, HashSet<string> seen, string kind,
        string raw, string normalised, bool valid)
    {
        var key = kind + "|" + (normalised.Length > 0 ? normalised : raw);
        if (!seen.Add(key)) return;
        var field = new OcrFieldCheck();
        field.Kind = kind;
        field.Raw = raw;
        field.Normalised = normalised;
        field.Valid = valid;
        field.NeedsReview = true; // engine has no confidence; dates/times must be confirmed
        outcome.Fields.Add(field);
    }

    private static bool IsValidDate(int year, int month, int day)
    {
        if (year < 1900 || year > 2100) return false;
        if (month < 1 || month > 12) return false;
        if (day < 1) return false;
        return day <= DateTime.DaysInMonth(year, month);
    }

    /// <summary>
    /// Heuristic text score. This is NOT a confidence value: it only compares
    /// candidate engines for the same pixels, so it must not reward verbosity or
    /// punish normal spacing.
    ///   * CJK 1.2 / letter-or-digit 1.0 (dense information),
    ///   * a space between two Latin letters is normal in English ("Lab Report"):
    ///     only a space next to a *one-character token* is a fragmentation sign
    ///     ("N ote s", "w o r l d") and is penalised,
    ///   * replacement/private-use/control characters are heavily penalised, so
    ///     a long garbage candidate cannot beat a short clean one,
    ///   * other punctuation contributes almost nothing.
    /// </summary>
    private static double ScoreText(string text)
    {
        int valid;
        int fragments;
        int suspicious;
        return ScoreText(text, out valid, out fragments, out suspicious);
    }

    private static double ScoreText(string text, out int validChars, out int spaceFragments, out int suspiciousChars)
    {
        validChars = 0;
        spaceFragments = 0;
        suspiciousChars = 0;
        if (text == null) return 0;
        var score = 0.0;
        for (var i = 0; i < text.Length; i++)
        {
            var c = text[i];
            if (IsCjk(c))
            {
                score += 1.2;
                validChars++;
            }
            else if (char.IsLetterOrDigit(c))
            {
                score += 1.0;
                validChars++;
            }
            else if (c == ' ')
            {
                score += 0.05;
            }
            else if (c == '\n')
            {
                score += 0.1;
            }
            else if (c == '\uFFFD' || c == '\u25A1' || c == '\u25A0' ||
                     (c >= '\uE000' && c <= '\uF8FF') ||
                     (c < ' ' && c != '\t' && c != '\r'))
            {
                score -= 10.0;
                suspiciousChars++;
            }
            else if (IsCommonPunctuation(c))
            {
                score += 0.02;
            }
        }
        spaceFragments = CountSpaceFragments(text);
        score -= 3.0 * spaceFragments;
        return score;
    }

    /// <summary>
    /// Number of spaces that split a Latin word into one-character fragments.
    /// "Lab Report" => 0 (normal English spacing); "N ote s" => 2.
    /// </summary>
    private static int CountSpaceFragments(string text)
    {
        var fragments = 0;
        foreach (var line in text.Split('\n'))
        {
            for (var i = 1; i + 1 < line.Length; i++)
            {
                if (line[i] != ' ') continue;
                if (!IsAsciiLetter(line[i - 1]) || !IsAsciiLetter(line[i + 1])) continue;
                var left = 0;
                for (var k = i - 1; k >= 0 && IsAsciiLetter(line[k]); k--) left++;
                var right = 0;
                for (var k = i + 1; k < line.Length && IsAsciiLetter(line[k]); k++) right++;
                if (left == 1 || right == 1) fragments++;
            }
        }
        return fragments;
    }

    private static double QualityFrom(double score, int validChars)
    {
        if (validChars <= 0) return 0;
        var quality = score / (validChars + 1.0);
        return quality < 0 ? 0 : quality;
    }

    /// <summary>Per-character heuristic quality of one candidate line.</summary>
    private static double LineQuality(string text)
    {
        int valid;
        int fragments;
        int suspicious;
        var score = ScoreText(text, out valid, out fragments, out suspicious);
        return QualityFrom(score, valid);
    }

    /// <summary>
    /// Text density check used only for image orientation retry: a page-sized
    /// bitmap that yields almost no characters is a strong sign of a rotated or
    /// broken image (a rotated page can still produce a few garbage glyphs with
    /// a high per-character score).
    /// </summary>
    private static bool IsSparse(OcrPageOutcome outcome)
    {
        if (outcome == null) return true;
        var pixels = (long)outcome.Width * outcome.Height;
        if (pixels < 800000L) return false;
        return outcome.ValidChars * 1000000.0 / pixels < 6.0;
    }

    /// <summary>A page is worth one bounded retry when the heuristic looks bad.</summary>
    private static bool IsLowQuality(OcrPageOutcome outcome)
    {
        if (outcome == null) return true;
        if (outcome.ValidChars < 8) return true;
        if (outcome.Quality < 0.72) return true;
        return outcome.SpaceFragments > Math.Max(2, outcome.ValidChars / 12);
    }

    /// <summary>
    /// True when the page yields enough text at a good per-character quality to
    /// stop the orientation retry loop. Density is used because a rotated page
    /// can produce a few garbage glyphs that still look "clean" per character.
    /// </summary>
    private static bool IsWellOriented(OcrPageOutcome outcome)
    {
        if (outcome == null || IsLowQuality(outcome) || IsSparse(outcome)) return false;
        return outcome.Quality >= 0.9;
    }

    /// <summary>
    /// Table-like evidence: several rows, most of them multi-cell, and the
    /// engine's own line segmentation is visibly more fragmented than the row
    /// grid. Only then is the text field emitted in row order; otherwise the
    /// engine reading order is kept untouched.
    /// </summary>
    private static bool ShouldUseRowText(OcrPageOutcome outcome)
    {
        if (outcome.Rows.Count < 2) return false;
        var multiCellRows = 0;
        var totalCells = 0;
        foreach (var row in outcome.Rows)
        {
            totalCells += row.Cells.Count;
            if (row.Cells.Count >= 3) multiCellRows++;
        }
        if (multiCellRows < 2) return false;
        if (totalCells < outcome.Rows.Count * 2) return false;
        return outcome.Lines.Count >= outcome.Rows.Count * 1.4;
    }

    /// <summary>True when candidate is a meaningfully better page candidate.</summary>
    private static bool IsBetter(OcrPageOutcome candidate, OcrPageOutcome current)
    {
        if (candidate == null) return false;
        if (current == null) return true;
        // Orientation attempts are compared by how much text was recovered first:
        // a correctly rotated page yields far more characters than a garbled one,
        // even though garbage CJK can score well per character.
        if (candidate.ValidChars > current.ValidChars * 1.3 &&
            candidate.Quality >= Math.Max(0.8, current.Quality - 0.2)) return true;
        if (candidate.ValidChars >= current.ValidChars * 0.9 &&
            candidate.Quality > current.Quality + 0.05) return true;
        if (candidate.ValidChars >= current.ValidChars * 0.9 &&
            Math.Abs(candidate.Quality - current.Quality) <= 0.05 &&
            candidate.ValidChars > current.ValidChars * 1.15) return true;
        return false;
    }

    private static string SanitizeText(string text)
    {
        if (text == null) return "";
        var sb = new StringBuilder(text.Length);
        for (var i = 0; i < text.Length; i++)
        {
            var c = text[i];
            if (char.IsHighSurrogate(c) && i + 1 < text.Length && char.IsLowSurrogate(text[i + 1]))
            {
                sb.Append(c);
                sb.Append(text[i + 1]);
                i++;
                continue;
            }
            if (char.IsSurrogate(c))
            {
                sb.Append('\uFFFD');
                continue;
            }
            sb.Append(c);
        }
        return sb.ToString();
    }

    private static bool IsCommonPunctuation(char c)
    {
        return c == ',' || c == '.' || c == ';' || c == ':' || c == '-' || c == '/' ||
               c == '(' || c == ')' || c == '[' || c == ']' || c == '%' || c == '+' ||
               c == '=' || c == '\'' || c == '"' || c == '，' || c == '。' || c == '：' ||
               c == '；' || c == '（' || c == '）' || c == '、';
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

    // --------------------------------------------------------------- self-test

    private static int _selfTestsPassed;
    private static int _selfTestsFailed;

    private static void CheckSelf(string name, bool ok, string detail)
    {
        if (ok) _selfTestsPassed++; else _selfTestsFailed++;
        var sb = new StringBuilder();
        sb.Append("{\"event\":\"self-test\",\"name\":").Append(Json.Str(name));
        sb.Append(",\"passed\":").Append(ok ? "true" : "false");
        sb.Append(",\"detail\":").Append(Json.Str(detail));
        sb.Append('}');
        _out.Write(sb.ToString());
        _out.Write('\n');
        _out.Flush();
    }

    private static OcrLineInfo SelfLine(string text, double x, double y, double width, double height,
                                       string[] words)
    {
        var line = new OcrLineInfo();
        line.Text = text;
        line.X = x;
        line.Y = y;
        line.Width = width;
        line.Height = height;
        var step = words.Length == 0 ? width : width / words.Length;
        for (var i = 0; i < words.Length; i++)
        {
            var word = new OcrWordInfo();
            word.Text = words[i];
            word.X = x + i * step;
            word.Y = y;
            word.Width = step * 0.9;
            word.Height = height;
            line.Words.Add(word);
        }
        return line;
    }

    /// <summary>
    /// Deterministic self-checks for the pure heuristics (no OCR engine needed):
    ///   ocr_host.exe --self-test
    /// Exits 1 when any check fails, so the build/quality scripts can gate on it.
    /// </summary>
    private static int RunSelfTest()
    {
        _selfTestsPassed = 0;
        _selfTestsFailed = 0;

        // --- ScoreText: normal English spacing must not be punished ----------
        var labReport = ScoreText("Lab Report");
        var fragmented = ScoreText("N ote s");
        CheckSelf("score_lab_report_beats_fragmented",
                  labReport > fragmented,
                  "Lab Report=" + Json.Num(labReport) + " vs N ote s=" + Json.Num(fragmented));
        int valid;
        int fragments;
        int suspicious;
        ScoreText("Lab Report", out valid, out fragments, out suspicious);
        CheckSelf("score_lab_report_no_fragments", fragments == 0, "fragments=" + fragments);
        ScoreText("N ote s", out valid, out fragments, out suspicious);
        CheckSelf("score_fragmented_spaces_counted", fragments == 2, "fragments=" + fragments);
        ScoreText("w o r l d", out valid, out fragments, out suspicious);
        CheckSelf("score_single_letters_counted", fragments == 4, "fragments=" + fragments);
        CheckSelf("score_hello_world_beats_letter_spam",
                  ScoreText("Hello world") > ScoreText("H e l l o w o r l d"),
                  "Hello world=" + Json.Num(ScoreText("Hello world")) + " vs spam=" +
                  Json.Num(ScoreText("H e l l o w o r l d")));
        var garbage = new string('\u25A1', 40);
        CheckSelf("score_long_garbage_cannot_win",
                  ScoreText(garbage) < ScoreText("Lab Report"),
                  "garbage=" + Json.Num(ScoreText(garbage)) + " vs clean=" + Json.Num(ScoreText("Lab Report")));
        CheckSelf("score_empty_is_zero", Math.Abs(ScoreText("")) < 0.0001, "score=" + Json.Num(ScoreText("")));
        CheckSelf("score_cjk_spacing_not_fragmented",
                  ScoreText("项 目 周 会 纪 要", out valid, out fragments, out suspicious) >= 0 && fragments == 0,
                  "fragments=" + fragments);

        // --- mixed-line candidate selection ----------------------------------
        var primary = new OcrPageOutcome();
        primary.Language = "zh-Hans-CN";
        primary.Lines.Add(SelfLine("N ote s", 100, 100, 180, 26, new string[] { "N", "ote", "s" }));
        primary.Lines.Add(SelfLine("项目周会纪要", 100, 150, 220, 30, new string[] { "项目周会纪要" }));
        primary.Text = "N ote s\n项目周会纪要";
        var english = new OcrPageOutcome();
        english.Language = "en-US";
        english.Lines.Add(SelfLine("Lab Report", 100, 100, 180, 26, new string[] { "Lab", "Report" }));
        english.Lines.Add(SelfLine("项目周会纪要", 100, 150, 220, 30, new string[] { "项目周会纪要" }));
        english.Text = "Lab Report\n项目周会纪要";
        var candidates = new List<OcrPageOutcome>();
        candidates.Add(primary);
        candidates.Add(english);
        ApplyLineSelection(primary, candidates);
        CheckSelf("mixed_line_selection_picks_better_line",
                  primary.Lines[0].Text == "Lab Report" && primary.Lines[0].Source == "region",
                  "line0=" + primary.Lines[0].Text + "/" + primary.Lines[0].Source);
        CheckSelf("mixed_line_selection_keeps_cjk_line",
                  primary.Lines.Count == 2 && primary.Lines[1].Text == "项目周会纪要",
                  "lines=" + primary.Lines.Count);
        CheckSelf("mixed_line_selection_changed_count", primary.ChangedLines == 1,
                  "changed=" + primary.ChangedLines);

        // --- row grouping: engine line order must not assign a date to a row --
        var tableOutcome = new OcrPageOutcome();
        // Engine emitted row 2 first and split columns across several lines.
        tableOutcome.Lines.Add(SelfLine("2026-11-05 李娜", 100, 220, 260, 24,
                                        new string[] { "2026-11-05", "李娜" }));
        tableOutcome.Lines.Add(SelfLine("2026-11-04 张伟", 100, 120, 260, 24,
                                        new string[] { "2026-11-04", "张伟" }));
        tableOutcome.Lines.Add(SelfLine("150 项目评审", 420, 120, 260, 24,
                                        new string[] { "150", "项目评审" }));
        tableOutcome.Lines.Add(SelfLine("90 材料整理", 420, 220, 260, 24,
                                        new string[] { "90", "材料整理" }));
        BuildRows(tableOutcome);
        CheckSelf("rows_grouped_by_y_not_line_order",
                  tableOutcome.Rows.Count == 2 &&
                  tableOutcome.Rows[0].Text.Contains("2026-11-04") &&
                  tableOutcome.Rows[0].Text.Contains("150") &&
                  tableOutcome.Rows[1].Text.Contains("2026-11-05") &&
                  tableOutcome.Rows[1].Text.Contains("90"),
                  "rows=" + tableOutcome.Rows.Count + " first=" + tableOutcome.Rows[0].Text);
        CheckSelf("rows_cells_ordered_by_x",
                  tableOutcome.Rows.Count > 0 && tableOutcome.Rows[0].Cells.Count >= 2 &&
                  tableOutcome.Rows[0].Cells[0].X < tableOutcome.Rows[0].Cells[1].X,
                  "cells=" + (tableOutcome.Rows.Count > 0 ? tableOutcome.Rows[0].Cells.Count : 0));
        CheckSelf("row_order_text_selected_for_tables", ShouldUseRowText(tableOutcome),
                  "rows=" + tableOutcome.Rows.Count + " lines=" + tableOutcome.Lines.Count);
        var paragraph = new OcrPageOutcome();
        paragraph.Lines.Add(SelfLine("这是一页普通正文第一行", 100, 100, 400, 30,
                                     new string[] { "这是一页普通正文第一行" }));
        paragraph.Lines.Add(SelfLine("这是普通正文第二行内容", 100, 150, 400, 30,
                                     new string[] { "这是普通正文第二行内容" }));
        paragraph.Lines.Add(SelfLine("这是普通正文第三行内容", 100, 200, 400, 30,
                                     new string[] { "这是普通正文第三行内容" }));
        BuildRows(paragraph);
        CheckSelf("row_order_text_not_used_for_paragraph", !ShouldUseRowText(paragraph),
                  "rows=" + paragraph.Rows.Count + " lines=" + paragraph.Lines.Count);

        // --- field format validation -----------------------------------------
        var fields = new OcrPageOutcome();
        fields.Text = "日期：2026年11月4日 时间：14:30 工时：2.5小时 分钟：150";
        BuildFields(fields);
        var dateOk = false;
        var timeOk = false;
        var hoursOk = false;
        var minutesOk = false;
        foreach (var field in fields.Fields)
        {
            if (field.Kind == "date" && field.Valid && field.Normalised == "2026-11-04") dateOk = true;
            if (field.Kind == "time" && field.Valid && field.Normalised == "14:30") timeOk = true;
            if (field.Kind == "hours" && field.Valid) hoursOk = true;
            if (field.Kind == "minutes" && field.Valid) minutesOk = true;
        }
        CheckSelf("fields_valid_date", dateOk, "normalised date");
        CheckSelf("fields_valid_time", timeOk, "normalised time");
        CheckSelf("fields_valid_hours", hoursOk, "hours");
        CheckSelf("fields_valid_minutes", minutesOk, "minutes");

        var badFields = new OcrPageOutcome();
        badFields.Text = "日期：2026年13月40日 时间：25:99";
        BuildFields(badFields);
        var dateInvalid = false;
        var timeInvalid = false;
        foreach (var field in badFields.Fields)
        {
            if (field.Kind == "date" && !field.Valid) dateInvalid = true;
            if (field.Kind == "time" && !field.Valid) timeInvalid = true;
        }
        CheckSelf("fields_invalid_date_marked", dateInvalid, "2026年13月40日");
        CheckSelf("fields_invalid_time_marked", timeInvalid, "25:99");
        CheckSelf("fields_keep_raw_text",
                  fields.Fields.Count > 0 && fields.Fields[0].Raw.Length > 0,
                  "raw=" + (fields.Fields.Count > 0 ? fields.Fields[0].Raw : ""));

        // --- robustness ------------------------------------------------------
        var dirty = "a" + '\uD800' + "b";
        var clean = SanitizeText(dirty);
        var hasSurrogate = false;
        foreach (var c in clean) { if (char.IsSurrogate(c)) { hasSurrogate = true; break; } }
        CheckSelf("sanitize_lone_surrogate", !hasSurrogate && clean.Contains("\uFFFD"),
                  "clean=" + Json.Str(clean));

        var summary = new StringBuilder();
        summary.Append("{\"event\":\"self-test-summary\",\"passed\":").Append(_selfTestsPassed);
        summary.Append(",\"failed\":").Append(_selfTestsFailed);
        summary.Append(",\"total\":").Append(_selfTestsPassed + _selfTestsFailed);
        summary.Append('}');
        _out.Write(summary.ToString());
        _out.Write('\n');
        _out.Flush();
        return _selfTestsFailed == 0 ? 0 : 1;
    }

    private static int ExitCodeFor(int ok, int failed)
    {
        if (failed == 0 && ok > 0) return 0;
        if (ok > 0) return 1;
        return 2;
    }
}
