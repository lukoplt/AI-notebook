using System.Text;

namespace AINotebook.Core.Ingestion;

/// <summary>Strict, scalar-bounded decoding without buffering a second copy of the input.</summary>
public static class TextDecoding
{
    private const int ByteBufferSize = 8192;
    private const int CharacterBufferSize = 4096;
    private static readonly Encoding StrictUtf8 = new UTF8Encoding(false, true);
    private static readonly Encoding StrictUtf16Le = new UnicodeEncoding(false, false, true);
    private static readonly Encoding StrictUtf16Be = new UnicodeEncoding(true, false, true);
    private static readonly Encoding StrictCp1250;

    static TextDecoding()
    {
        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
        StrictCp1250 = Encoding.GetEncoding(1250,
            EncoderFallback.ExceptionFallback, DecoderFallback.ExceptionFallback);
    }

    public static DecodedText Decode(byte[] bytes, string fallback, int maxScalars)
    {
        ArgumentNullException.ThrowIfNull(bytes);
        using var stream = new MemoryStream(bytes, writable: false);
        return Decode(stream, fallback, maxScalars);
    }

    /// <summary>
    /// Decodes from the current position to EOF, leaving the caller's stream open.
    /// A seekable stream permits a strict UTF-8 failure to retry cp1250 without retaining bytes.
    /// The file reader is responsible for enforcing the input byte limit.
    /// </summary>
    internal static DecodedText Decode(Stream stream, string fallback, int maxScalars,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(stream);
        if (!stream.CanRead || !stream.CanSeek)
            throw new ArgumentException("Text decoding requires a readable, seekable stream.", nameof(stream));
        if (fallback is not ("none" or "cp1250"))
            throw new FolderIngestionException("unsupportedEncoding");
        if (maxScalars < 0)
            throw new FolderIngestionException("textLimit");

        cancellationToken.ThrowIfCancellationRequested();
        long start = stream.Position;
        Span<byte> prefix = stackalloc byte[3];
        int prefixLength = 0;
        while (prefixLength < prefix.Length)
        {
            cancellationToken.ThrowIfCancellationRequested();
            int read = stream.Read(prefix[prefixLength..]);
            if (read == 0) break;
            prefixLength += read;
        }

        Encoding encoding = StrictUtf8;
        string name = "utf-8";
        int bomLength = 0;
        if (prefixLength >= 3 && prefix[0] == 0xef && prefix[1] == 0xbb && prefix[2] == 0xbf)
        {
            name = "utf-8-bom";
            bomLength = 3;
        }
        else if (prefixLength >= 2 && prefix[0] == 0xff && prefix[1] == 0xfe)
        {
            encoding = StrictUtf16Le;
            name = "utf-16le";
            bomLength = 2;
        }
        else if (prefixLength >= 2 && prefix[0] == 0xfe && prefix[1] == 0xff)
        {
            encoding = StrictUtf16Be;
            name = "utf-16be";
            bomLength = 2;
        }

        stream.Position = checked(start + bomLength);
        try
        {
            return new DecodedText(DecodeCore(stream, encoding, maxScalars, false, cancellationToken), name);
        }
        catch (DecoderFallbackException) when (bomLength == 0 && fallback == "cp1250")
        {
            stream.Position = start;
            try
            {
                return new DecodedText(DecodeCore(stream, StrictCp1250, maxScalars, true, cancellationToken),
                    "windows-1250");
            }
            catch (DecoderFallbackException)
            {
                throw new FolderIngestionException("unsupportedEncoding");
            }
        }
        catch (DecoderFallbackException)
        {
            // An explicit BOM commits to its codec; malformed content cannot trigger fallback.
            throw new FolderIngestionException("unsupportedEncoding");
        }
    }

    private static string DecodeCore(Stream stream, Encoding encoding, int maxScalars,
        bool rejectUndefinedCp1250, CancellationToken cancellationToken)
    {
        Decoder decoder = encoding.GetDecoder();
        byte[] bytes = new byte[ByteBufferSize];
        char[] characters = new char[CharacterBufferSize];
        var result = new StringBuilder(Math.Min(maxScalars, CharacterBufferSize));
        int scalarCount = 0;
        char pendingHighSurrogate = '\0';

        while (true)
        {
            cancellationToken.ThrowIfCancellationRequested();
            int read = stream.Read(bytes, 0, bytes.Length);
            bool flush = read == 0;
            if (rejectUndefinedCp1250)
            {
                for (int i = 0; i < read; i++)
                    if (bytes[i] is 0x81 or 0x83 or 0x88 or 0x90 or 0x98)
                        throw new DecoderFallbackException("Undefined Windows-1250 byte.");
            }

            int offset = 0;
            bool completed;
            do
            {
                cancellationToken.ThrowIfCancellationRequested();
                decoder.Convert(bytes, offset, read - offset, characters, 0, characters.Length,
                    flush, out int bytesUsed, out int charsUsed, out completed);
                offset += bytesUsed;
                AppendScalars(result, characters.AsSpan(0, charsUsed), ref pendingHighSurrogate,
                    ref scalarCount, maxScalars);
            } while (!completed);

            if (!flush) continue;
            if (pendingHighSurrogate != '\0')
                throw new DecoderFallbackException("Incomplete UTF-16 surrogate pair.");
            return result.ToString();
        }
    }

    private static void AppendScalars(StringBuilder result, ReadOnlySpan<char> characters,
        ref char pendingHighSurrogate, ref int scalarCount, int maximum)
    {
        foreach (char value in characters)
        {
            if (pendingHighSurrogate != '\0')
            {
                if (!char.IsLowSurrogate(value))
                    throw new DecoderFallbackException("Invalid UTF-16 surrogate pair.");
                if (scalarCount == maximum)
                    throw new FolderIngestionException("textLimit");
                // Neither half is appended before the complete scalar passes the limit check.
                result.Append(pendingHighSurrogate);
                result.Append(value);
                pendingHighSurrogate = '\0';
                scalarCount++;
            }
            else if (char.IsHighSurrogate(value))
            {
                pendingHighSurrogate = value;
            }
            else
            {
                if (char.IsLowSurrogate(value))
                    throw new DecoderFallbackException("Unpaired UTF-16 low surrogate.");
                if (scalarCount == maximum)
                    throw new FolderIngestionException("textLimit");
                result.Append(value);
                scalarCount++;
            }
        }
    }
}
