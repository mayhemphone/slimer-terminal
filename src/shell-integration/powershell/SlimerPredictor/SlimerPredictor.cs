// slimer: PSReadLine predictor that reports the command line to Slimer
// autocomplete with OSC 7704. See ../README.md and docs/slimer/AUTOCOMPLETE.md.
//
// UNTESTED: written without a .NET SDK or PowerShell at hand. Build and
// try it on Windows before relying on it.
//
// Why a predictor: PSReadLine has no "buffer changed" hook. ICommandPredictor
// .GetSuggestion is the only callback PSReadLine makes on every edit of the
// line, and it receives the parsed input. This predictor uses it purely as
// that hook: it writes one OSC 7704 report to the console and returns no
// suggestions.
//
// Known limits of the hook (PSReadLine Prediction.cs):
// - It is not called for an empty or whitespace-only buffer, nor for input
//   containing a newline. slimer.psm1 wraps a few deleting keys to cover the
//   empty case; multi-line editing is not reported.
// - PredictionContext.CursorPosition is always the end of the input. We ask
//   PSReadLine for the real cursor through PSConsoleReadLine.GetBufferState
//   (reflection, public API) and use it only when its buffer matches the
//   input we were given.
// - Cursor-only movement does not trigger a query, so the reported cursor
//   can be stale until the next edit.
// - It runs on a thread-pool thread while PSReadLine waits (about 20 ms) for
//   predictors. The work here is a few microseconds; Console.Out is
//   synchronized, so the report is never split by PSReadLine's own writes.
//
// The wire format lives in SlimerReporter.BuildReport / PercentEncode and
// mirrors New-SlimerAutocompleteReport / ConvertTo-SlimerPercentEncoding in
// slimer.psm1. Change both together.

using System;
using System.Collections.Generic;
using System.Management.Automation.Subsystem.Prediction;
using System.Reflection;
using System.Text;
using System.Threading;

namespace Slimer.PowerShell
{
    public sealed class SlimerPredictor : ICommandPredictor
    {
        public static readonly Guid PredictorId = new Guid("5a11ae00-7704-4c0d-9e5a-51a1e0c0de01");

        public Guid Id => PredictorId;

        public string Name => "Slimer";

        public string Description => "Reports the command line to the Slimer terminal for its autocomplete popup. Never suggests anything.";

        Dictionary<string, string>? System.Management.Automation.Subsystem.ISubsystem.FunctionsToDefine => null;

        public SuggestionPackage GetSuggestion(PredictionClient client, PredictionContext context, CancellationToken cancellationToken)
        {
            try
            {
                if (client.Kind == PredictionClientKind.Terminal)
                {
                    string input = context.InputAst.Extent.Text;
                    int cursor = input.Length;
                    SlimerReporter.TryGetReadLineCursor(input, ref cursor);
                    SlimerReporter.Report(input, cursor);
                }
            }
            catch
            {
                // Never disturb the line editor.
            }

            return default;
        }

        public bool CanAcceptFeedback(PredictionClient client, PredictorFeedbackKind feedback) => false;

        public void OnSuggestionDisplayed(PredictionClient client, uint session, int countOrIndex) { }

        public void OnSuggestionAccepted(PredictionClient client, uint session, string acceptedSuggestion) { }

        public void OnCommandLineAccepted(PredictionClient client, IReadOnlyList<string> history) { }

        public void OnCommandLineExecuted(PredictionClient client, string commandLine, bool success) { }
    }

    /// <summary>
    /// Builds and writes OSC 7704 reports. Configured by slimer.psm1.
    /// </summary>
    public static class SlimerReporter
    {
        public const int MaxBufferBytes = 4096;

        private static readonly object Sync = new object();
        private static bool _enabled;
        private static string? _token;
        private static int _processId;
        private static string _keymap = "emacs";
        private static bool _asciiOnly = true;
        private static string? _last;

        private static MethodInfo? _getBufferState;
        private static bool _getBufferStateResolved;

        public static void Configure(string? token, int processId, string keymap, bool asciiOnly)
        {
            lock (Sync)
            {
                _token = string.IsNullOrEmpty(token) ? null : token;
                _processId = processId;
                _keymap = keymap;
                _asciiOnly = asciiOnly;
                _last = null;
                _enabled = true;
            }
        }

        /// <summary>Called at every prompt with the current edit mode and console encoding.</summary>
        public static void Update(string keymap, bool asciiOnly)
        {
            lock (Sync)
            {
                _keymap = keymap;
                _asciiOnly = asciiOnly;
            }
        }

        /// <summary>A new prompt always reports, even if the buffer matches the last one.</summary>
        public static void ResetDedupe()
        {
            lock (Sync)
            {
                _last = null;
            }
        }

        public static void Disable()
        {
            lock (Sync)
            {
                _enabled = false;
                _last = null;
            }
        }

        public static void Report(string buffer, int cursorUtf16)
        {
            string report;
            lock (Sync)
            {
                if (!_enabled)
                {
                    return;
                }

                string key = cursorUtf16.ToString(System.Globalization.CultureInfo.InvariantCulture) + ":" + _keymap + ":" + buffer;
                if (string.Equals(key, _last, StringComparison.Ordinal))
                {
                    return;
                }

                _last = key;
                report = BuildReport(buffer, cursorUtf16, _keymap, _token, _processId, _asciiOnly, deactivate: false);
            }

            Console.Out.Write(report);
            Console.Out.Flush();
        }

        /// <summary>
        /// Replace the end-of-input cursor with PSReadLine's real cursor when
        /// PSReadLine's buffer is exactly the input we were given.
        /// </summary>
        public static void TryGetReadLineCursor(string input, ref int cursor)
        {
            try
            {
                MethodInfo? method = ResolveGetBufferState();
                if (method == null)
                {
                    return;
                }

                object?[] args = new object?[] { null, 0 };
                method.Invoke(null, args);
                if (args[0] is string line && args[1] is int pos &&
                    string.Equals(line, input, StringComparison.Ordinal) &&
                    pos >= 0 && pos <= input.Length)
                {
                    cursor = pos;
                }
            }
            catch
            {
                // Keep the end-of-input cursor.
            }
        }

        private static MethodInfo? ResolveGetBufferState()
        {
            if (_getBufferStateResolved)
            {
                return _getBufferState;
            }

            foreach (Assembly asm in AppDomain.CurrentDomain.GetAssemblies())
            {
                Type? type = asm.GetType("Microsoft.PowerShell.PSConsoleReadLine", throwOnError: false);
                if (type == null)
                {
                    continue;
                }

                _getBufferState = type.GetMethod(
                    "GetBufferState",
                    BindingFlags.Public | BindingFlags.Static,
                    binder: null,
                    types: new[] { typeof(string).MakeByRefType(), typeof(int).MakeByRefType() },
                    modifiers: null);
                break;
            }

            _getBufferStateResolved = true;
            return _getBufferState;
        }

        // ---- wire format (mirrors slimer.psm1) ----

        public static string BuildReport(string buffer, int cursorUtf16, string keymap, string? token, int processId, bool asciiOnly, bool deactivate)
        {
            if (!IsValidKeymap(keymap))
            {
                keymap = "other";
            }

            var sb = new StringBuilder(buffer.Length + 64);
            sb.Append("\u001b]7704;v=1");
            if (!string.IsNullOrEmpty(token))
            {
                sb.Append(";n=").Append(token);
            }

            if (processId > 0)
            {
                sb.Append(";p=").Append(processId.ToString(System.Globalization.CultureInfo.InvariantCulture));
            }

            if (deactivate)
            {
                sb.Append(";d=1");
                buffer = string.Empty;
                cursorUtf16 = 0;
            }

            cursorUtf16 = Math.Max(0, Math.Min(cursorUtf16, buffer.Length));
            string limited = LimitUtf8(buffer, MaxBufferBytes, out bool truncated);
            int c = CodePointCount(buffer, cursorUtf16);

            sb.Append(";c=").Append(c.ToString(System.Globalization.CultureInfo.InvariantCulture));
            sb.Append(";k=").Append(keymap);
            sb.Append(";t=").Append(truncated ? '1' : '0');
            sb.Append(";b=");
            PercentEncode(sb, limited, asciiOnly);
            sb.Append('\u0007');
            return sb.ToString();
        }

        private static bool IsValidKeymap(string keymap)
        {
            if (string.IsNullOrEmpty(keymap) || keymap.Length > 16)
            {
                return false;
            }

            foreach (char ch in keymap)
            {
                bool ok = (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '_' || ch == '-';
                if (!ok)
                {
                    return false;
                }
            }

            return true;
        }

        /// <summary>
        /// '%', ';', C0, DEL and C1 become %XX (uppercase); with asciiOnly every
        /// non-ASCII character becomes %XX of its UTF-8 bytes; the rest is raw.
        /// </summary>
        public static void PercentEncode(StringBuilder sb, string text, bool asciiOnly)
        {
            for (int i = 0; i < text.Length; i++)
            {
                char ch = text[i];
                int n = 1;
                if (char.IsHighSurrogate(ch) && i + 1 < text.Length && char.IsLowSurrogate(text[i + 1]))
                {
                    n = 2;
                }

                if (n == 1 && (ch < 0x20 || ch == 0x7F || ch == '%' || ch == ';'))
                {
                    AppendHex(sb, (byte)ch);
                }
                else if ((n == 1 && ch >= 0x80 && ch <= 0x9F) || (asciiOnly && (n == 2 || ch >= 0x80)))
                {
                    foreach (byte b in Encoding.UTF8.GetBytes(text.Substring(i, n)))
                    {
                        AppendHex(sb, b);
                    }
                }
                else
                {
                    sb.Append(text, i, n);
                }

                i += n - 1;
            }
        }

        private static void AppendHex(StringBuilder sb, byte b)
        {
            const string Hex = "0123456789ABCDEF";
            sb.Append('%').Append(Hex[b >> 4]).Append(Hex[b & 0xF]);
        }

        /// <summary>Longest prefix of at most maxBytes UTF-8 bytes, cut on a code point boundary.</summary>
        public static string LimitUtf8(string text, int maxBytes, out bool truncated)
        {
            int bytes = 0;
            for (int i = 0; i < text.Length;)
            {
                char ch = text[i];
                int n = 1;
                int len;
                if (char.IsHighSurrogate(ch) && i + 1 < text.Length && char.IsLowSurrogate(text[i + 1]))
                {
                    n = 2;
                    len = 4;
                }
                else if (ch < 0x80)
                {
                    len = 1;
                }
                else if (ch < 0x800)
                {
                    len = 2;
                }
                else
                {
                    len = 3;
                }

                if (bytes + len > maxBytes)
                {
                    truncated = true;
                    return text.Substring(0, i);
                }

                bytes += len;
                i += n;
            }

            truncated = false;
            return text;
        }

        /// <summary>Code points in the first length UTF-16 units of text.</summary>
        public static int CodePointCount(string text, int length)
        {
            int count = 0;
            for (int i = 0; i < length && i < text.Length; i++)
            {
                if (char.IsLowSurrogate(text[i]) && i > 0 && char.IsHighSurrogate(text[i - 1]))
                {
                    continue;
                }

                count++;
            }

            return count;
        }
    }
}
