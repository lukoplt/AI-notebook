# E-mail ingestion (.eml / .msg) — normative contract v1

*Status: 2026-10-10. Fixture: `Tests/fixtures/contracts/ingestion-mail-v1.json` (assets in `Tests/fixtures/ingestion/formats/`). Executable reference: `tools/contracts/gen_mail_fixtures.py` (`--check` must pass). Swift (`MailReader`, `MailText`, `CompoundFile`) and C# (`MailReader`, `MailText`, `CompoundFile`) must reproduce every case exactly (UTF-8 byte equality). Extends `folder-rag-v1.md` §3 (canonical text) without changing it; no schema change.*

## 1. Scope and safety

`.eml` and `.msg` files are `SourceType.email` (raw value `"email"`). The reader is dependency-free and bounded on both platforms. It reads only header fields, the message body and attachment **names**. Attachment payloads, embedded messages, RTF bodies, macros and any other object are never decoded, read, extracted or executed.

Format selection: bytes starting with the CFB signature `D0 CF 11 E0 A1 B1 1A E1` are read as MSG (an Outlook message saved as `.eml` still works). Otherwise a `.msg` file is `corruptArchive`; any other file is read as RFC 5322/MIME.

## 2. Canonical text

```
Subject: <subject>
From: <from>
To: <to>
Cc: <cc>
Date: <date>
Attachments: <name>, <name>

<body>
```

- Labels are fixed English on both platforms (never localized). A line whose value is empty is omitted; `Attachments` is omitted when no named attachment exists.
- Header block and body are separated by one blank line; either may be empty (no separator then).
- Every header value is whitespace-collapsed: runs of `ScalarChunker` whitespace become one U+0020, leading/trailing whitespace is removed.
- Body: CRLF and lone CR become LF; leading/trailing whitespace is trimmed; interior text is unchanged.
- `title` = the subject when non-empty, else none (the descriptor then falls back to the file name). `kind = "email"`, no pages, no sheets, no encoding.
- The scalar limit (`maxExtractedChars`) applies to the complete canonical text (`textLimit`).

## 3. Charsets (shared by EML and MSG)

Labels are ASCII-lowercased and trimmed of space, tab, CR, LF, `"` and `'`:

| Codec | Labels / MAPI code pages |
|---|---|
| `utf-8` (strict, same rules as `TextDecoding`) | `utf-8`, `utf8`, `us-ascii`, `ascii`, `ansi_x3.4-1968`; 65001, 20127 |
| `windows-1252` | `iso-8859-1`, `iso8859-1`, `latin1`, `l1`, `windows-1252`, `cp1252`; 1252, 28591 |
| `iso-8859-2` | `iso-8859-2`, `iso8859-2`, `latin2`, `l2`; 28592 |
| `windows-1250` | `windows-1250`, `cp1250`, `x-cp1250`; 1250 |

Any other or missing label is `auto`. Single-byte codecs use fixed tables (fixture `charset-table-*`); undefined positions decode to U+FFFD. `utf-8` and `auto` decode strict UTF-8; invalid UTF-8 falls back to `windows-1250` when the folder's `encodingFallback` is `cp1250`, else to `windows-1252`. Decoding therefore never fails (no `unsupportedEncoding` for mail). UTF-16LE (MSG) decodes unpaired surrogates and an odd trailing byte to U+FFFD.

## 4. EML (RFC 5322 / MIME)

- A leading mbox `From ` line is skipped. Lines end at LF; a preceding CR is not content.
- Header block: up to the first empty line. A line starting with SP/HT continues the previous header (unfolding keeps the leading whitespace); a line without `:` (or starting with `:`) ends the open header and is ignored. Names are trimmed and ASCII-lowercased; the first occurrence wins. Values are decoded `auto` (raw 8-bit headers).
- `Subject`, `From`, `To`, `Cc`, `Date` are RFC 2047-decoded and collapsed; `Date` is the header text (not reformatted).
- **Encoded words** `=?charset[*lang]?B|Q?payload?=`: payload of printable ASCII without `?` or whitespace. B: alphabet only after trailing `=` padding, length mod 4 ≠ 1. Q: `_` is space, `=XX` hex, otherwise literal; a malformed word stays literal text. Whitespace between two words is dropped; consecutive words with the same lowercased label concatenate their bytes before decoding (a UTF-8 sequence may span words).
- **Parameters** (`Content-Type`, `Content-Disposition`): `;`-separated outside double quotes; quoted values unescape `\x`. Names are lowercased; the first wins. File names: RFC 2231 `name*` (`charset'lang'pct`), else numbered continuations `name*0[*]`, `name*1[*]` … (at most 100), else the plain value (encoded words allowed). `filename` (disposition) wins over `name` (content type).
- A missing or slash-less content type is `text/plain` without parameters. `multipart/*` with a non-empty `boundary` is split at lines equal to `--boundary` or `--boundary--` (trailing SP/HT ignored); the line break before a delimiter belongs to it; preamble and epilogue are ignored; a missing close delimiter ends the last part at the end of the entity.
- Transfer encodings: `base64` ignores every non-alphabet byte and drops a trailing single sextet; `quoted-printable` decodes `=XX` (either case), removes `=` followed by optional SP/HT and a line end (or the end of data), keeps other `=` literally. Anything else is identity.
- **Attachment**: disposition `attachment`, or a non-empty file name with a disposition other than `inline`. Named attachments are listed in document order; unnamed ones are not listed.
- **Body**: `multipart/alternative` uses its first non-attachment `text/plain` child, else the first non-attachment child that yields a body. Other multiparts join the non-empty bodies of their non-attachment children with `\n\n`. A non-attachment `text/plain` leaf is its decoded text; `text/html` is converted (§6); other leaves have no body.
- Bounds: MIME depth ≤ 32 and ≤ 10 000 entities, else `officeLimit`. Decoded body bytes are debited from `maxOfficeDecompressedBytes` (`officeLimit`). The file itself is bounded by `maxFileBytes` (`fileLimit`).

## 5. MSG (MS-OXMSG in MS-CFB)

**Compound file** (`CompoundFile`): header signature, byte order `FFFE`, mini sector shift 6, mini stream cutoff 4096, and version 3 with 512-byte or version 4 with 4096-byte sectors — anything else is `corruptArchive`. The sector count is `ceil((fileLength − sectorSize) / sectorSize)`; a short last sector is zero-padded. DIFAT: the 109 header entries, then at most `numDIFAT` chained DIFAT sectors (revisit or out-of-range index → corrupt). FAT sectors are the first `numFAT` non-free DIFAT entries; fewer, out of range or duplicated → corrupt. Every chain walk rejects a revisited, out-of-range or table-external index (`corruptArchive`) and stops once enough sectors for the stream size are read; a chain shorter than the size is corrupt. The directory chain is read to ENDOFCHAIN; more than 100 000 entries → `officeLimit`. Entry types other than 0/1/2/5, or a name length outside 2…64 / odd for an allocated entry → corrupt; entry 0 must be the root. Version 3 uses only the low 32 bits of a stream size. A stream larger than the file is corrupt. Streams below 4096 bytes live in the mini stream (the root entry's FAT chain) addressed through the mini FAT. Child lookup walks the red-black tree iteratively in order (left, node, right) with cycle detection; names are compared ASCII-uppercased and the first wins. Every sector read is debited from `maxOfficeDecompressedBytes` (`officeLimit`).

**Properties** (top-level storage; substreams `__substg1.0_PPPPTTTT`, type `001F` UTF-16LE with trailing NULs removed, else `001E` bytes with trailing NUL bytes removed, decoded with the message codec):

- Message codec: `PR_MESSAGE_CODEPAGE` (0x3FFD, PT_LONG in `__properties_version1.0`, 32-byte header then 16-byte entries; the first entry per id wins), mapped per §3; absent or unknown → `auto`. HTML codec: `PR_INTERNET_CPID` (0x3FDE) when present, else the message codec.
- Subject `0x0037`. From: name = `0x0C1A`, else `0x0042`; e-mail = the first of `0x5D01`, `0x0C1F`, `0x0065` that contains `@` (Exchange X.500 addresses are skipped). `name <email>` when both are non-empty and differ, else the non-empty one. To `0x0E04`, Cc `0x0E03` (display strings).
- Date: `PR_CLIENT_SUBMIT_TIME` (0x0039), else `PR_MESSAGE_DELIVERY_TIME` (0x0E06), PT_SYSTIME FILETIME formatted UTC `YYYY-MM-DDTHH:MM:SSZ`; 0 or a year above 9999 is empty.
- Body: `PR_BODY` (0x1000); when empty, `PR_HTML` (0x1013: binary `0102` decoded with the HTML codec, else a string property) converted per §6. Compressed RTF (`0x1009`) is not decoded.
- Attachments: child storages `__attach_version1.0_#XXXXXXXX` in ASCII order of their uppercased names; name = `0x3707`, else `0x3704`, else `0x3001`; empty names are not listed; more than 10 000 → `officeLimit`.

## 6. HTML to text

Comments, `<!…>` and `<?…>` are removed; the content of `head`, `script`, `style` and `title` is skipped up to the next ASCII-case-insensitive `</name` and its `>`. A tag is `<`, optional `/`, an ASCII letter and alphanumerics, then attributes with quote-aware scanning to `>`; any other `<` is text. `br` emits a line break (at most two consecutive); block elements (`address article aside blockquote center dd div dl dt fieldset figure footer form h1–h6 header hr li main nav ol p pre section table tr ul`, opening or closing) start a new line; `td`/`th` separate by a space; other tags are dropped. Character references: `&amp; &lt; &gt; &quot; &apos; &nbsp;` and numeric `&#N;` / `&#xH;` (1–8 digits; 0, surrogates or above U+10FFFF → U+FFFD); the `;` must occur within 11 characters, otherwise `&` is literal. Whitespace (including NBSP) collapses to one space, never at a line start or end; trailing line breaks are removed.

## 7. Error codes

`fileLimit`, `officeLimit`, `textLimit`, `corruptArchive` — all already mapped by `IngestionErrorText` (no new strings). Re-extraction: these files were never sources before (unsupported extension), so `ExtractorRevision` is unchanged.

## 8. Fixture

`{contract, version, limits{maxMimeDepth, maxMimeParts, maxCompoundEntries, maxAttachments}, cases[{name, operation, input, expected}]}`. Operations: `extract` (`input{asset, fallback, limits}` → `expected{text, title}` or `{error}`; run through the bounded document extractor with the kind detected from the asset name), `decode-header`, `html-to-text`, `decode-charset` (`bytes`, `charset`, `fallback`), `filetime`. All messages are synthetic and generated programmatically (including the CFB files); no real mailbox data is used.
