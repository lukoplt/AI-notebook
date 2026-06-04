# AINotebook.Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL — read `~/.claude/skills/superpowers/skills/writing-plans/SKILL.md` and follow it exactly. Execute one task at a time, in order. Within a task, follow the numbered TDD steps verbatim: write the failing test, run the exact `dotnet test --filter` command shown (confirm **Expected: FAIL**), implement the production code, re-run (confirm **Expected: PASS**), then commit with the exact message given. Do NOT skip the failing-test step, do NOT batch tasks, and do NOT mark a step `[x]` until its command has actually been run and matches the stated expectation. All code in this plan is complete and final — type it as written; the constants, SQL, JSON shapes, byte layouts, and test assertions are ported 1:1 from the Swift `AINotebookCore` and must not be approximated.

**Goal:** A faithful C# / .NET 10 port of the macOS `AINotebookCore` library — storage, ingestion, retrieval, chat, and transformations — delivered as a **headless, fully unit-tested** class library (`AINotebook.Core`) with **no UI dependency**. The port must be **byte-compatible** with the existing SQLite database (identical schema, FTS5 virtual tables + sync triggers, `grdb_migrations` tracking, TEXT date format, raw little-endian float32 embedding BLOBs) and reproduce the **identical algorithms** (deterministic chunker, RRF retrieval, citation parser, NDJSON Ollama protocol) so the two implementations can be diffed behaviorally.

**Architecture:** `Microsoft.Data.Sqlite` (bundled SQLite with FTS5 via `SQLitePCLRaw.bundle_e_sqlite3`) for persistence, queries through **Dapper** and mutations through hand-written SQL in repositories on a `NotebookStore` that runs an ordered `Migrator` and seeds `BuiltinTransformations`. Text extraction is an `ITextExtractor` strategy (`PlainTextExtractor`, `PdfTextExtractor` over **PdfPig**, `OfficeTextExtractor` over `System.IO.Compression` + `System.Xml`, `WebTextExtractor` over `HttpClient` + **AngleSharp**). Ollama is reached through `OllamaClient` over `HttpClient` with line-streamed `IAsyncEnumerable<T>` NDJSON. Retrieval fuses vector cosine + FTS5 BM25 via Reciprocal Rank Fusion in `Retriever`. The library mirrors the Swift `AINotebookCore` 1:1.

**Tech Stack:** C# / .NET 10 (`net10.0`); xUnit; Microsoft.Data.Sqlite 9.\*, SQLitePCLRaw.bundle_e_sqlite3 2.\*, Dapper 2.\*, UglyToad.PdfPig 0.1.\*, AngleSharp 1.\*. (Core is platform-neutral — builds/tests on macOS or Windows; only the Plan 2 WinUI app is Windows-only.)

---

## File Structure

All paths are relative to the repository root. The library lives under `windows/src/AINotebook.Core/` and tests under `windows/tests/AINotebook.Core.Tests/`.

**Solution / projects**
- `windows/AINotebook.sln` — solution tying the Core library and its test project together.
- `windows/src/AINotebook.Core/AINotebook.Core.csproj` — `net10.0` class library; the production NuGet `PackageReference`s.
- `windows/tests/AINotebook.Core.Tests/AINotebook.Core.Tests.csproj` — xUnit test project referencing `AINotebook.Core`.

**Models/** (records, enums, exceptions — namespace `AINotebook.Core.Models`, errors in `AINotebook.Core`)
- `windows/src/AINotebook.Core/Models/Notebook.cs` — `Notebook` record.
- `windows/src/AINotebook.Core/Models/Source.cs` — `Source` record + `SourceType` enum (string values + `Detect`) + `SourceStatus` enum (string values + `IsTerminal`).
- `windows/src/AINotebook.Core/Models/SourceChunk.cs` — `SourceChunk` + `ChunkDraft` records.
- `windows/src/AINotebook.Core/Models/EmbeddingVector.cs` — `EmbeddingVector` (encode/decode) + `StoredEmbedding` record.
- `windows/src/AINotebook.Core/Models/Chat.cs` — `ChatSession`, `ChatRole`, `Citation`, `ChatMessage`.
- `windows/src/AINotebook.Core/Models/Note.cs` — `Note`, `NoteOrigin`, `NoteAttachment`, `NoteVersion`, `NoteVersionReason`.
- `windows/src/AINotebook.Core/Models/Transformation.cs` — `Transformation`, `TransformationScope`, `TransformationRun`.
- `windows/src/AINotebook.Core/Models/AppLanguage.cs` — `AppLanguage` enum (`en`/`cs`).
- `windows/src/AINotebook.Core/Errors.cs` — cross-cutting exceptions (`StoreException`, `EmbedderException`). `ExtractorException`/`IngestionException`/`OllamaException`/`TransformationException` live beside their consuming code (Extractors/Ingestion/Ollama/Rag).

**Storage/** (namespace `AINotebook.Core.Storage`)
- `windows/src/AINotebook.Core/Storage/SqliteDate.cs` — TEXT `yyyy-MM-dd HH:mm:ss.fff` UTC date encode/decode.
- `windows/src/AINotebook.Core/Storage/StorePath.cs` — `StorePath` (`InMemory`, `Production()`).
- `windows/src/AINotebook.Core/Storage/Migrator.cs` — ordered v1..v9 migrations tracked in `grdb_migrations`.
- `windows/src/AINotebook.Core/Storage/NotebookStore.cs` — connection, migration, seeding, CRUD (+ partials for sources/chat/embeddings/notes/transformations).
- `windows/src/AINotebook.Core/Storage/BuiltinTransformations.cs` — seed/refresh built-in transformations.

**Extractors/** (namespace `AINotebook.Core.Extractors`)
- `windows/src/AINotebook.Core/Extractors/ITextExtractor.cs` — `ITextExtractor` + `ExtractedText`.
- `windows/src/AINotebook.Core/Extractors/PlainTextExtractor.cs`, `PdfTextExtractor.cs`, `OfficeTextExtractor.cs`, `WebTextExtractor.cs` — extractor implementations (+ `ExtractorException`).

**Ingestion/** (namespace `AINotebook.Core.Ingestion`)
- `windows/src/AINotebook.Core/Ingestion/Chunker.cs` — deterministic chunker.
- `windows/src/AINotebook.Core/Ingestion/IngestionService.cs` — extract → chunk → store → enqueue embedding (+ `IngestionException`).

**Ollama/** (namespace `AINotebook.Core.Ollama`)
- `windows/src/AINotebook.Core/Ollama/OllamaClient.cs` — `HttpClient` NDJSON client + adapters.
- `windows/src/AINotebook.Core/Ollama/OllamaDtos.cs` — `OllamaModel`, `OllamaPullEvent`, `OllamaChatMessage`, `OllamaChatChunk`, `OllamaChatOptions`, request/response DTOs.
- `windows/src/AINotebook.Core/Ollama/Interfaces.cs` — `IEmbeddingProducing`, `IChatStreaming`, `ChatTurn`. (`OllamaException` is defined in this namespace.)

**Rag/** (namespace `AINotebook.Core.Rag`)
- `windows/src/AINotebook.Core/Rag/Cosine.cs` — cosine similarity.
- `windows/src/AINotebook.Core/Rag/Embedder.cs`, `EmbeddingWorker.cs` — embedding batch + background worker.
- `windows/src/AINotebook.Core/Rag/Retriever.cs` — cosine + BM25 + RRF (`RetrievalHit` lives in Models).
- `windows/src/AINotebook.Core/Rag/CitationParser.cs` — `[N]` marker parser.
- `windows/src/AINotebook.Core/Rag/SystemPrompt.cs` — prompt composer.
- `windows/src/AINotebook.Core/Rag/ChatEngine.cs` — citation-aware streaming engine.
- `windows/src/AINotebook.Core/Rag/TransformationEngine.cs` — run templates, save as note (+ `TransformationException`).
- `windows/src/AINotebook.Core/Rag/NoteIndexer.cs` — chunk + index notes as shadow sources.

**Tests/** (namespace `AINotebook.Core.Tests`)
- `windows/tests/AINotebook.Core.Tests/SmokeTest.cs` — scaffold sanity test.
- `windows/tests/AINotebook.Core.Tests/Models/SourceTypeTests.cs`, `EmbeddingVectorTests.cs` — model unit tests.
- `windows/tests/AINotebook.Core.Tests/Storage/SqliteDateTests.cs` — date round-trip tests.
- `windows/tests/AINotebook.Core.Tests/Helpers/StubHttpMessageHandler.cs` — FIFO stub handler for Ollama tests (added by later tasks).

---

## Task 1: Scaffold the solution + projects

Stand up the `windows/` solution with an empty Core library and an xUnit test project, wire up the NuGet dependencies, and prove the toolchain works end-to-end with a trivial passing test.

> **Prerequisite:** the **.NET 10 SDK** must be installed (`dotnet --list-sdks` should show a `10.0.*` SDK; this project targets `net10.0`). This machine has 9.0.100 + 10.0.103.

**Files:**
- Create: `windows/AINotebook.sln`
- Create: `windows/src/AINotebook.Core/AINotebook.Core.csproj`
- Create: `windows/tests/AINotebook.Core.Tests/AINotebook.Core.Tests.csproj`
- Create: `windows/src/AINotebook.Core/Class1.cs` (deleted in this task)
- Create: `windows/tests/AINotebook.Core.Tests/UnitTest1.cs` (deleted in this task)
- Test: `windows/tests/AINotebook.Core.Tests/SmokeTest.cs`

- [ ] **Step 1: Create the solution and the two projects via the SDK CLI.**
  Run from the repository root:
  ```bash
  dotnet new sln -n AINotebook -o windows
  dotnet new classlib -n AINotebook.Core -f net10.0 -o windows/src/AINotebook.Core
  dotnet new xunit  -n AINotebook.Core.Tests -f net10.0 -o windows/tests/AINotebook.Core.Tests
  dotnet sln windows/AINotebook.sln add windows/src/AINotebook.Core/AINotebook.Core.csproj
  dotnet sln windows/AINotebook.sln add windows/tests/AINotebook.Core.Tests/AINotebook.Core.Tests.csproj
  dotnet add windows/tests/AINotebook.Core.Tests/AINotebook.Core.Tests.csproj reference windows/src/AINotebook.Core/AINotebook.Core.csproj
  ```
  Then delete the template files that `dotnet new` created (they collide with our own classes):
  ```bash
  rm windows/src/AINotebook.Core/Class1.cs
  rm windows/tests/AINotebook.Core.Tests/UnitTest1.cs
  ```

- [ ] **Step 2: Overwrite the Core `.csproj` with the production dependencies.**
  Replace the entire contents of `windows/src/AINotebook.Core/AINotebook.Core.csproj` with:
  ```xml
  <Project Sdk="Microsoft.NET.Sdk">

    <PropertyGroup>
      <TargetFramework>net10.0</TargetFramework>
      <RootNamespace>AINotebook.Core</RootNamespace>
      <AssemblyName>AINotebook.Core</AssemblyName>
      <ImplicitUsings>enable</ImplicitUsings>
      <Nullable>enable</Nullable>
      <LangVersion>latest</LangVersion>
      <TreatWarningsAsErrors>false</TreatWarningsAsErrors>
    </PropertyGroup>

    <ItemGroup>
      <PackageReference Include="Microsoft.Data.Sqlite" Version="9.*" />
      <PackageReference Include="SQLitePCLRaw.bundle_e_sqlite3" Version="2.*" />
      <PackageReference Include="Dapper" Version="2.*" />
      <PackageReference Include="UglyToad.PdfPig" Version="0.1.*" />
      <PackageReference Include="AngleSharp" Version="1.*" />
    </ItemGroup>

  </Project>
  ```

- [ ] **Step 3: Overwrite the test `.csproj` to enable nullable + implicit usings and keep the Core reference.**
  Replace the entire contents of `windows/tests/AINotebook.Core.Tests/AINotebook.Core.Tests.csproj` with:
  ```xml
  <Project Sdk="Microsoft.NET.Sdk">

    <PropertyGroup>
      <TargetFramework>net10.0</TargetFramework>
      <RootNamespace>AINotebook.Core.Tests</RootNamespace>
      <ImplicitUsings>enable</ImplicitUsings>
      <Nullable>enable</Nullable>
      <IsPackable>false</IsPackable>
      <IsTestProject>true</IsTestProject>
    </PropertyGroup>

    <ItemGroup>
      <PackageReference Include="Microsoft.NET.Test.Sdk" Version="17.*" />
      <PackageReference Include="xunit" Version="2.*" />
      <PackageReference Include="xunit.runner.visualstudio" Version="2.*" />
    </ItemGroup>

    <ItemGroup>
      <ProjectReference Include="..\..\src\AINotebook.Core\AINotebook.Core.csproj" />
    </ItemGroup>

  </Project>
  ```

- [ ] **Step 4: Write the failing smoke test.**
  Create `windows/tests/AINotebook.Core.Tests/SmokeTest.cs`:
  ```csharp
  namespace AINotebook.Core.Tests;

  public class SmokeTest
  {
      [Fact]
      public void Toolchain_Is_Wired()
      {
          Assert.Equal(4, 2 + 2);
      }
  }
  ```

- [ ] **Step 5: Run the smoke test.** (At this point the project restores its packages and builds.)
  ```bash
  dotnet test windows/AINotebook.sln --filter "FullyQualifiedName~SmokeTest"
  ```
  **Expected: PASS** (1 passed). If restore fails, confirm a `net10.0`-capable SDK is installed (Prerequisite above).

- [ ] **Step 6: Add a `.gitignore` for build artifacts and commit.**
  Create `windows/.gitignore`:
  ```gitignore
  bin/
  obj/
  *.user
  ```
  Then commit:
  ```bash
  git add windows/AINotebook.sln windows/src/AINotebook.Core/AINotebook.Core.csproj \
          windows/tests/AINotebook.Core.Tests/AINotebook.Core.Tests.csproj \
          windows/tests/AINotebook.Core.Tests/SmokeTest.cs windows/.gitignore
  git commit -m "$(cat <<'EOF'
  feat(windows): scaffold AINotebook.Core solution + xUnit test project

  net10.0 class library with Microsoft.Data.Sqlite + SQLitePCLRaw.bundle_e_sqlite3
  (FTS5), Dapper, UglyToad.PdfPig, AngleSharp; xUnit test project references Core.
  Smoke test green.

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

---

## Task 2: Domain models, enums, and exceptions

Port the entire model layer (records + enums) and the exception hierarchy from the SHARED TYPE CONTRACT. The two behaviorally interesting pieces — `SourceType.Detect` and the enum string round-trips — are TDD'd against the verbatim assertions in the extraction's `testsToPort`; the remaining records/enums/exceptions are plain data types added alongside.

**Files:**
- Create: `windows/src/AINotebook.Core/Models/SourceType` and `SourceStatus` (in `Source.cs`), `Notebook.cs`, `SourceChunk.cs`, `Chat.cs`, `Note.cs`, `Transformation.cs`, `AppLanguage.cs`, `Errors.cs`
- Test: `windows/tests/AINotebook.Core.Tests/Models/SourceTypeTests.cs`

- [ ] **Step 1: Write failing tests for `SourceType` (verbatim from extraction `SourceType.testRawValuesAreStable`, `testDetectFromFilenameMatchesExtension`, `testDetectReturnsNilForUnknown / Note`) and `SourceStatus`.**
  Create `windows/tests/AINotebook.Core.Tests/Models/SourceTypeTests.cs`:
  ```csharp
  using AINotebook.Core.Models;

  namespace AINotebook.Core.Tests.Models;

  public class SourceTypeTests
  {
      // SourceType.testRawValuesAreStable
      [Theory]
      [InlineData(SourceType.Pdf, "pdf")]
      [InlineData(SourceType.Text, "text")]
      [InlineData(SourceType.Markdown, "markdown")]
      [InlineData(SourceType.Web, "web")]
      [InlineData(SourceType.Docx, "docx")]
      [InlineData(SourceType.Pptx, "pptx")]
      [InlineData(SourceType.Xlsx, "xlsx")]
      [InlineData(SourceType.Note, "note")]
      public void RawValues_AreStable(SourceType type, string expected)
      {
          Assert.Equal(expected, type.RawValue());
          Assert.Equal(type, SourceTypeExtensions.FromRawValue(expected));
      }

      // SourceType.testDetectFromFilenameMatchesExtension
      [Theory]
      [InlineData("doc.pdf", SourceType.Pdf)]
      [InlineData("Notes.MD", SourceType.Markdown)] // case-insensitive
      [InlineData("plain.txt", SourceType.Text)]
      [InlineData("deck.pptx", SourceType.Pptx)]
      [InlineData("sheet.xlsx", SourceType.Xlsx)]
      [InlineData("memo.docx", SourceType.Docx)]
      [InlineData("readme.markdown", SourceType.Markdown)]
      public void Detect_MatchesExtension(string filename, SourceType expected)
      {
          Assert.Equal(expected, SourceTypeExtensions.Detect(filename));
      }

      // SourceType.testDetectReturnsNilForUnknown / Note
      [Theory]
      [InlineData("image.png")]
      [InlineData("noextension")]
      [InlineData("scratch.note")] // .note is NOT detectable from a filename
      public void Detect_ReturnsNull_ForUnknown(string filename)
      {
          Assert.Null(SourceTypeExtensions.Detect(filename));
      }

      [Fact]
      public void AllCases_Contains_Note()
      {
          Assert.Contains(SourceType.Note, Enum.GetValues<SourceType>());
      }

      // SourceStatus string values + IsTerminal
      [Theory]
      [InlineData(SourceStatus.Pending, "pending", false)]
      [InlineData(SourceStatus.Chunking, "chunking", false)]
      [InlineData(SourceStatus.Ready, "ready", true)]
      [InlineData(SourceStatus.Error, "error", true)]
      public void SourceStatus_RawValue_And_IsTerminal(SourceStatus status, string raw, bool isTerminal)
      {
          Assert.Equal(raw, status.RawValue());
          Assert.Equal(status, SourceStatusExtensions.FromRawValue(raw));
          Assert.Equal(isTerminal, status.IsTerminal());
      }
  }
  ```

- [ ] **Step 2: Run the test — it must fail to compile (types do not exist yet).**
  ```bash
  dotnet test windows/AINotebook.sln --filter "FullyQualifiedName~SourceTypeTests"
  ```
  **Expected: FAIL** (build error — `SourceType`/`SourceStatus`/extensions undefined).

- [ ] **Step 3: Implement `Source.cs` with the `SourceType`/`SourceStatus` enums and their string-value extensions.**
  Create `windows/src/AINotebook.Core/Models/Source.cs`. The enum string values are stored as the source column raw values; `Detect` mirrors `SourceType.detect(filename:)` exactly (pdf→Pdf, txt→Text, md/markdown→Markdown, docx/pptx/xlsx, else null — note that `.note` is intentionally NOT detectable).
  ```csharp
  using System.IO;

  namespace AINotebook.Core.Models;

  public enum SourceType { Pdf, Text, Markdown, Web, Docx, Pptx, Xlsx, Note }

  public static class SourceTypeExtensions
  {
      public static string RawValue(this SourceType type) => type switch
      {
          SourceType.Pdf => "pdf",
          SourceType.Text => "text",
          SourceType.Markdown => "markdown",
          SourceType.Web => "web",
          SourceType.Docx => "docx",
          SourceType.Pptx => "pptx",
          SourceType.Xlsx => "xlsx",
          SourceType.Note => "note",
          _ => throw new ArgumentOutOfRangeException(nameof(type), type, null)
      };

      public static SourceType FromRawValue(string raw) => raw switch
      {
          "pdf" => SourceType.Pdf,
          "text" => SourceType.Text,
          "markdown" => SourceType.Markdown,
          "web" => SourceType.Web,
          "docx" => SourceType.Docx,
          "pptx" => SourceType.Pptx,
          "xlsx" => SourceType.Xlsx,
          "note" => SourceType.Note,
          _ => throw new ArgumentOutOfRangeException(nameof(raw), raw, "Unknown SourceType raw value")
      };

      // DB-mapper aliases (consumed by NotebookStore partials in Tasks 7-11).
      public static string ToDb(this SourceType v) => v.RawValue();
      public static SourceType FromDb(string raw) => FromRawValue(raw);

      /// <summary>Best-effort detection from a filename. Returns null for unknown extensions.
      /// Mirrors Swift SourceType.detect(filename:). Note: ".note" is never detected here.</summary>
      public static SourceType? Detect(string filename)
      {
          // Path.GetExtension returns ".md" (with the dot); trim it and lowercase to match
          // (filename as NSString).pathExtension.lowercased().
          var ext = Path.GetExtension(filename).TrimStart('.').ToLowerInvariant();
          return ext switch
          {
              "pdf" => SourceType.Pdf,
              "txt" => SourceType.Text,
              "md" or "markdown" => SourceType.Markdown,
              "docx" => SourceType.Docx,
              "pptx" => SourceType.Pptx,
              "xlsx" => SourceType.Xlsx,
              _ => null
          };
      }
  }

  public enum SourceStatus { Pending, Chunking, Ready, Error }

  public static class SourceStatusExtensions
  {
      public static string RawValue(this SourceStatus status) => status switch
      {
          SourceStatus.Pending => "pending",
          SourceStatus.Chunking => "chunking",
          SourceStatus.Ready => "ready",
          SourceStatus.Error => "error",
          _ => throw new ArgumentOutOfRangeException(nameof(status), status, null)
      };

      public static SourceStatus FromRawValue(string raw) => raw switch
      {
          "pending" => SourceStatus.Pending,
          "chunking" => SourceStatus.Chunking,
          "ready" => SourceStatus.Ready,
          "error" => SourceStatus.Error,
          _ => throw new ArgumentOutOfRangeException(nameof(raw), raw, "Unknown SourceStatus raw value")
      };

      // DB-mapper aliases (consumed by NotebookStore partials in Tasks 7-11).
      public static string ToDb(this SourceStatus v) => v.RawValue();
      public static SourceStatus FromDb(string raw) => FromRawValue(raw);

      /// <summary>true for Ready/Error; false for Pending/Chunking (Swift SourceStatus.isTerminal).</summary>
      public static bool IsTerminal(this SourceStatus status) =>
          status is SourceStatus.Ready or SourceStatus.Error;
  }

  public record Source(
      long? Id,
      long NotebookId,
      SourceType Type,
      string Title,
      string? Uri,
      string? RawPath,
      SourceStatus Status,
      string? Error,
      DateTime IngestedAt);
  ```

- [ ] **Step 4: Run the test.**
  ```bash
  dotnet test windows/AINotebook.sln --filter "FullyQualifiedName~SourceTypeTests"
  ```
  **Expected: PASS** (all theory cases green).

- [ ] **Step 5: Add the remaining model records + enums (no behavior, plain data — matches the SHARED TYPE CONTRACT verbatim).**
  Create `windows/src/AINotebook.Core/Models/Notebook.cs`:
  ```csharp
  namespace AINotebook.Core.Models;

  public record Notebook(
      long? Id,
      string Name,
      string Description,
      DateTime CreatedAt,
      DateTime UpdatedAt);
  ```
  Create `windows/src/AINotebook.Core/Models/SourceChunk.cs`:
  ```csharp
  namespace AINotebook.Core.Models;

  public record SourceChunk(
      long? Id,
      long SourceId,
      int Ord,
      string Text,
      int TokenCount,
      int? PageHint);

  public sealed record ChunkDraft(
      string Text,
      int TokenCount,
      int? PageHint = null);
  ```
  Create `windows/src/AINotebook.Core/Models/Chat.cs`:
  ```csharp
  namespace AINotebook.Core.Models;

  public record ChatSession(
      long? Id,
      long NotebookId,
      string Title,
      DateTime CreatedAt);

  public enum ChatRole { System, User, Assistant }

  public static class ChatRoleExtensions
  {
      public static string RawValue(this ChatRole role) => role switch
      {
          ChatRole.System => "system",
          ChatRole.User => "user",
          ChatRole.Assistant => "assistant",
          _ => throw new ArgumentOutOfRangeException(nameof(role), role, null)
      };

      // Swift decode fallback on unknown raw value => .user
      public static ChatRole FromRawValue(string raw) => raw switch
      {
          "system" => ChatRole.System,
          "assistant" => ChatRole.Assistant,
          _ => ChatRole.User
      };

      // DB-mapper aliases (consumed by NotebookStore partials in Tasks 7-11).
      public static string ToDb(this ChatRole v) => v.RawValue();
      public static ChatRole FromDb(string raw) => FromRawValue(raw);
  }

  public record Citation(
      int Marker,
      long ChunkId,
      long SourceId,
      string Snippet);

  public record ChatMessage(
      long? Id,
      long SessionId,
      ChatRole Role,
      string Content,
      IReadOnlyList<Citation> Citations,
      DateTime CreatedAt);
  ```
  Create `windows/src/AINotebook.Core/Models/Note.cs`:
  ```csharp
  namespace AINotebook.Core.Models;

  public enum NoteOrigin { Manual, Chat, Transformation }

  public static class NoteOriginExtensions
  {
      public static string RawValue(this NoteOrigin origin) => origin switch
      {
          NoteOrigin.Manual => "manual",
          NoteOrigin.Chat => "chat",
          NoteOrigin.Transformation => "transformation",
          _ => throw new ArgumentOutOfRangeException(nameof(origin), origin, null)
      };

      public static NoteOrigin FromRawValue(string raw) => raw switch
      {
          "manual" => NoteOrigin.Manual,
          "chat" => NoteOrigin.Chat,
          "transformation" => NoteOrigin.Transformation,
          _ => throw new ArgumentOutOfRangeException(nameof(raw), raw, "Unknown NoteOrigin raw value")
      };

      // DB-mapper aliases (consumed by NotebookStore partials in Tasks 7-11).
      public static string ToDb(this NoteOrigin v) => v.RawValue();
      public static NoteOrigin FromDb(string raw) => FromRawValue(raw);
  }

  public record Note(
      long? Id,
      long NotebookId,
      string Title,
      string BodyMd,
      NoteOrigin Origin,
      long? OriginRef,
      long? AutoSourceId,
      string NoteUuid,
      DateTime CreatedAt,
      DateTime UpdatedAt);

  public record NoteAttachment(
      long? Id,
      long NoteId,
      string NoteUuid,
      string Filename,
      string Mime,
      long ByteSize,
      DateTime CreatedAt);

  public enum NoteVersionReason { Autosave, Manual, Restore }

  public static class NoteVersionReasonExtensions
  {
      public static string RawValue(this NoteVersionReason reason) => reason switch
      {
          NoteVersionReason.Autosave => "autosave",
          NoteVersionReason.Manual => "manual",
          NoteVersionReason.Restore => "restore",
          _ => throw new ArgumentOutOfRangeException(nameof(reason), reason, null)
      };

      public static NoteVersionReason FromRawValue(string raw) => raw switch
      {
          "autosave" => NoteVersionReason.Autosave,
          "manual" => NoteVersionReason.Manual,
          "restore" => NoteVersionReason.Restore,
          _ => throw new ArgumentOutOfRangeException(nameof(raw), raw, "Unknown NoteVersionReason raw value")
      };

      // DB-mapper aliases (consumed by NotebookStore partials in Tasks 7-11).
      public static string ToDb(this NoteVersionReason v) => v.RawValue();
      public static NoteVersionReason FromDb(string raw) => FromRawValue(raw);
  }

  public record NoteVersion(
      long? Id,
      long NoteId,
      string Title,
      string BodyMd,
      DateTime SavedAt,
      NoteVersionReason Reason);
  ```
  Create `windows/src/AINotebook.Core/Models/Transformation.cs`:
  ```csharp
  namespace AINotebook.Core.Models;

  public enum TransformationScope { Source, Notebook }

  public static class TransformationScopeExtensions
  {
      public static string RawValue(this TransformationScope scope) => scope switch
      {
          TransformationScope.Source => "source",
          TransformationScope.Notebook => "notebook",
          _ => throw new ArgumentOutOfRangeException(nameof(scope), scope, null)
      };

      public static TransformationScope FromRawValue(string raw) => raw switch
      {
          "source" => TransformationScope.Source,
          "notebook" => TransformationScope.Notebook,
          _ => throw new ArgumentOutOfRangeException(nameof(raw), raw, "Unknown TransformationScope raw value")
      };

      // DB-mapper aliases (consumed by NotebookStore partials in Tasks 7-11).
      public static string ToDb(this TransformationScope v) => v.RawValue();
      public static TransformationScope FromDb(string raw) => FromRawValue(raw);
  }

  public record Transformation(
      long? Id,
      string Name,
      string PromptTemplate,
      TransformationScope Scope,
      bool IsBuiltin,
      string Description);

  public record TransformationRun(
      long? Id,
      long TransformationId,
      long? SourceId,
      long? ResultNoteId,
      DateTime RanAt);
  ```
  Create `windows/src/AINotebook.Core/Models/AppLanguage.cs` (string values "en"/"cs"):
  ```csharp
  namespace AINotebook.Core.Models;

  public enum AppLanguage { English, Czech }

  public static class AppLanguageExtensions
  {
      public static string RawValue(this AppLanguage language) => language switch
      {
          AppLanguage.English => "en",
          AppLanguage.Czech => "cs",
          _ => "en",
      };

      public static string DisplayName(this AppLanguage language) => language switch
      {
          AppLanguage.English => "English",
          AppLanguage.Czech => "Čeština",
          _ => "English",
      };

      // Returns null on unknown raw value (does NOT throw); Task 26's AppLanguageTests
      // and LocaleDetection bind to this nullable form.
      public static AppLanguage? FromRawValue(string raw) => raw switch
      {
          "en" => AppLanguage.English,
          "cs" => AppLanguage.Czech,
          _ => null,
      };
  }
  ```

- [ ] **Step 6: Add the cross-cutting exceptions (`StoreException`, `EmbedderException`).**
  Create `windows/src/AINotebook.Core/Errors.cs`. Each exception carries the same data the Swift `enum` cases carry, so tests can assert on type + data. `StoreException` reproduces the Swift `LocalizedError` messages verbatim. Only the two cross-cutting families live here; `ExtractorException`, `IngestionException`, `OllamaException`, and `TransformationException` are defined later beside their consuming code (Tasks 15/18/19/25).
  ```csharp
  namespace AINotebook.Core;

  // ----- StoreError (verbatim LocalizedError messages from Swift StoreError) -----
  public abstract class StoreException : Exception
  {
      protected StoreException(string message) : base(message) { }

      public sealed class NotebookNotFound : StoreException
      {
          public long Id { get; }
          public NotebookNotFound(long id) : base($"Notebook {id} not found.") => Id = id;
      }

      public sealed class InvalidNotebookName : StoreException
      {
          public string Name { get; }
          public InvalidNotebookName(string name) : base($"Invalid notebook name: \"{name}\".") => Name = name;
      }

      public sealed class SourceNotFound : StoreException
      {
          public long Id { get; }
          public SourceNotFound(long id) : base($"Source #{id} not found.") => Id = id;
      }

      public sealed class InvalidSourceTitle : StoreException
      {
          public string Title { get; }
          public InvalidSourceTitle(string title) : base($"Invalid source title: \"{title}\".") => Title = title;
      }
  }

  // Note: ExtractorException, IngestionException, OllamaException, and
  // TransformationException are NOT defined here. They live in their own
  // (sub-)namespaces alongside the code + tests that bind to them:
  //   ExtractorException      -> Task 15 (AINotebook.Core.Extractors)
  //   IngestionException      -> Task 18 (AINotebook.Core.Ingestion)
  //   OllamaException         -> Task 19 (AINotebook.Core.Ollama)
  //   TransformationException -> Task 25 (AINotebook.Core.Rag)
  // Task 2's Errors.cs owns only the cross-cutting StoreException and EmbedderException.

  // ----- Embedder errors -----
  public abstract class EmbedderException : Exception
  {
      protected EmbedderException(string message) : base(message) { }

      public sealed class ResponseSizeMismatch : EmbedderException
      {
          public int Expected { get; }
          public int Got { get; }
          public ResponseSizeMismatch(int expected, int got)
              : base($"Embedding response size mismatch: expected {expected}, got {got}.")
          { Expected = expected; Got = got; }
      }
  }
  ```

- [ ] **Step 7: Build the whole solution to confirm every new type compiles, then re-run the model tests.**
  ```bash
  dotnet build windows/AINotebook.sln
  dotnet test windows/AINotebook.sln --filter "FullyQualifiedName~SourceTypeTests"
  ```
  **Expected: PASS** (build succeeds; SourceTypeTests green).

- [ ] **Step 8: Commit.**
  ```bash
  git add windows/src/AINotebook.Core/Models windows/src/AINotebook.Core/Errors.cs \
          windows/tests/AINotebook.Core.Tests/Models/SourceTypeTests.cs
  git commit -m "$(cat <<'EOF'
  feat(core): domain models, enums, and exception hierarchy

  Records + enums per the type contract (Notebook/Source/SourceChunk/ChunkDraft/
  Chat*/Note*/Transformation*/AppLanguage) with stable string raw values, plus the
  cross-cutting StoreException and EmbedderException in Errors.cs. (ExtractorException/
  IngestionException/OllamaException/TransformationException live with their consuming
  code in later tasks' own namespaces.) SourceType.Detect and enum raw values
  ported 1:1 from Swift with verbatim testsToPort assertions.

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

---

## Task 3: `SqliteDate` helper

GRDB stores Swift `Date` in DATETIME columns as TEXT `yyyy-MM-dd HH:mm:ss.SSS` (locale `en_US_POSIX`, time zone GMT/UTC), always 3-digit milliseconds — verbatim production sample `2026-05-24 21:50:39.694`. The C# port must write `DateTime.ToString("yyyy-MM-dd HH:mm:ss.fff")` in UTC and parse it back as UTC. This task ports that exact format helper and pins it with a round-trip test plus a known-string test.

**Files:**
- Create: `windows/src/AINotebook.Core/Storage/SqliteDate.cs`
- Test: `windows/tests/AINotebook.Core.Tests/Storage/SqliteDateTests.cs`

- [ ] **Step 1: Write the failing tests.**
  Create `windows/tests/AINotebook.Core.Tests/Storage/SqliteDateTests.cs`:
  ```csharp
  using System.Globalization;
  using AINotebook.Core.Storage;

  namespace AINotebook.Core.Tests.Storage;

  public class SqliteDateTests
  {
      [Fact]
      public void RoundTrips_Utc_DateTime()
      {
          // A UTC instant with non-zero milliseconds, truncated to ms precision.
          var original = new DateTime(2026, 5, 24, 21, 50, 39, 694, DateTimeKind.Utc);

          string text = SqliteDate.ToDb(original);
          Assert.Equal("2026-05-24 21:50:39.694", text);

          DateTime parsed = SqliteDate.FromDb(text);
          Assert.Equal(DateTimeKind.Utc, parsed.Kind);
          Assert.Equal(original, parsed);
      }

      [Fact]
      public void ToDb_AlwaysWrites_ThreeMillisecondDigits()
      {
          // Whole second => still ".000"
          var whole = new DateTime(2026, 1, 2, 3, 4, 5, 0, DateTimeKind.Utc);
          Assert.Equal("2026-01-02 03:04:05.000", SqliteDate.ToDb(whole));
      }

      [Fact]
      public void ToDb_Converts_Local_To_Utc()
      {
          // A Local kind value must be normalized to UTC before formatting.
          var utc = new DateTime(2026, 5, 24, 21, 50, 39, 694, DateTimeKind.Utc);
          var local = utc.ToLocalTime(); // Kind == Local
          Assert.Equal("2026-05-24 21:50:39.694", SqliteDate.ToDb(local));
      }

      [Fact]
      public void FromDb_Parses_Known_Production_String_As_Utc()
      {
          // Verbatim production sample from the extraction.
          DateTime parsed = SqliteDate.FromDb("2026-05-24 21:50:39.694");
          Assert.Equal(DateTimeKind.Utc, parsed.Kind);
          Assert.Equal(
              new DateTime(2026, 5, 24, 21, 50, 39, 694, DateTimeKind.Utc),
              parsed);
      }
  }
  ```

- [ ] **Step 2: Run — must fail (type does not exist).**
  ```bash
  dotnet test windows/AINotebook.sln --filter "FullyQualifiedName~SqliteDateTests"
  ```
  **Expected: FAIL** (build error — `SqliteDate` undefined).

- [ ] **Step 3: Implement `SqliteDate`.**
  Create `windows/src/AINotebook.Core/Storage/SqliteDate.cs`. Format with the invariant culture (mirrors `en_US_POSIX`); always normalize to UTC before formatting; parse strictly with `DateTimeStyles.AssumeUniversal` so the result Kind is UTC.
  ```csharp
  using System.Globalization;

  namespace AINotebook.Core.Storage;

  /// <summary>
  /// Date storage format used by the SQLite schema, ported 1:1 from GRDB's
  /// DateFormatter (dateFormat "yyyy-MM-dd HH:mm:ss.SSS", locale en_US_POSIX,
  /// timeZone GMT). Always 3 millisecond digits; values are written and read as UTC.
  /// </summary>
  public static class SqliteDate
  {
      public const string Format = "yyyy-MM-dd HH:mm:ss.fff";

      /// <summary>Serialize a DateTime to the TEXT form, normalized to UTC.</summary>
      public static string ToDb(DateTime value)
      {
          // Unspecified is treated as already-UTC; Local is converted; Utc stays.
          DateTime utc = value.Kind switch
          {
              DateTimeKind.Utc => value,
              DateTimeKind.Local => value.ToUniversalTime(),
              _ => DateTime.SpecifyKind(value, DateTimeKind.Utc)
          };
          return utc.ToString(Format, CultureInfo.InvariantCulture);
      }

      /// <summary>Parse the TEXT form back into a UTC DateTime. Also tolerates a
      /// numeric unix epoch (GRDB's decoder accepts it; the app never wrote that
      /// form, but we accept it for robustness).</summary>
      public static DateTime FromDb(string text)
      {
          // Numeric unix-epoch fallback: only when the value has no date/time
          // separators (so a real "yyyy-MM-dd HH:mm:ss.fff" string never matches).
          if (double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var epoch)
              && !text.Contains('-') && !text.Contains(':'))
          {
              return DateTimeOffset.FromUnixTimeMilliseconds((long)(epoch * 1000)).UtcDateTime;
          }
          var parsed = DateTime.ParseExact(
              text,
              Format,
              CultureInfo.InvariantCulture,
              DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal);
          return DateTime.SpecifyKind(parsed, DateTimeKind.Utc);
      }
  }
  ```

- [ ] **Step 4: Run the tests.**
  ```bash
  dotnet test windows/AINotebook.sln --filter "FullyQualifiedName~SqliteDateTests"
  ```
  **Expected: PASS** (4 passed).

- [ ] **Step 5: Commit.**
  ```bash
  git add windows/src/AINotebook.Core/Storage/SqliteDate.cs \
          windows/tests/AINotebook.Core.Tests/Storage/SqliteDateTests.cs
  git commit -m "$(cat <<'EOF'
  feat(storage): SqliteDate helper (TEXT yyyy-MM-dd HH:mm:ss.fff, UTC)

  Ports GRDB's DATETIME TEXT format 1:1: always 3 ms digits, written/parsed as
  UTC, invariant culture. Round-trips and parses the verbatim production string
  "2026-05-24 21:50:39.694" as UTC.

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

---

## Task 4: `EmbeddingVector` encode/decode

Embeddings are stored as a raw contiguous **little-endian IEEE-754 float32** BLOB — no header, no length prefix, no dimension field (the dimension lives in a separate INTEGER column). `byte_count = dim * 4`; decoding requires `byte_count % 4 == 0` or it throws. This task ports `EmbeddingVector.asData()` / `init(data:)` to `ToBytes()` / `FromBytes(byte[])`, with the verbatim `testsToPort` assertions, and adds the `StoredEmbedding` record.

**Files:**
- Create: `windows/src/AINotebook.Core/Models/EmbeddingVector.cs`
- Test: `windows/tests/AINotebook.Core.Tests/Models/EmbeddingVectorTests.cs`

- [ ] **Step 1: Write the failing tests (verbatim from extraction: `testRoundTripsThroughData`, `testRejectsMisalignedData`, `testDimReportsCount`) plus a little-endian layout assertion.**
  Create `windows/tests/AINotebook.Core.Tests/Models/EmbeddingVectorTests.cs`:
  ```csharp
  using AINotebook.Core;
  using AINotebook.Core.Models;

  namespace AINotebook.Core.Tests.Models;

  public class EmbeddingVectorTests
  {
      // EmbeddingVector: testRoundTripsThroughData
      [Fact]
      public void RoundTrips_Through_Bytes()
      {
          var values = new float[] { 0.1f, -0.2f, 3.14f, -42.0f };
          var vec = new EmbeddingVector(values);

          byte[] bytes = vec.ToBytes();
          Assert.Equal(16, bytes.Length); // 4 floats x 4 bytes

          var decoded = EmbeddingVector.FromBytes(bytes);
          Assert.Equal(values, decoded.Values);
          Assert.Equal(4, decoded.Dim);
      }

      // EmbeddingVector: testRejectsMisalignedData
      [Fact]
      public void Rejects_Misaligned_Bytes()
      {
          var ex = Assert.Throws<EmbedderException.MisalignedByteCount>(
              () => EmbeddingVector.FromBytes(new byte[] { 0, 1, 2 }));
          Assert.Equal(3, ex.ByteCount);
      }

      // EmbeddingVector: testDimReportsCount
      [Fact]
      public void Dim_Reports_Count()
      {
          var values = new float[768];
          var vec = new EmbeddingVector(values);
          Assert.Equal(768, vec.Dim);
      }

      [Fact]
      public void ToBytes_Is_LittleEndian_Float32()
      {
          // 1.0f in IEEE-754 little-endian is 00 00 80 3F.
          var vec = new EmbeddingVector(new[] { 1.0f });
          byte[] bytes = vec.ToBytes();
          Assert.Equal(new byte[] { 0x00, 0x00, 0x80, 0x3F }, bytes);
      }

      [Fact]
      public void FromBytes_Reads_LittleEndian_Float32()
      {
          // Bytes for -0.0506f (approx) come from the production sample "715D4FBD".
          var bytes = new byte[] { 0x71, 0x5D, 0x4F, 0xBD };
          var vec = EmbeddingVector.FromBytes(bytes);
          Assert.Single(vec.Values);
          Assert.Equal(-0.0506f, vec.Values[0], 3); // 3 decimal places of tolerance
      }
  }
  ```

- [ ] **Step 2: Add the `MisalignedByteCount` exception case.**
  The Swift `EmbeddingVector.DecodeError.misalignedByteCount(Int)` is the decode-side error. Add it to the embedder error family in `windows/src/AINotebook.Core/Errors.cs`, inside the existing `EmbedderException` class (after `ResponseSizeMismatch`):
  ```csharp
      public sealed class MisalignedByteCount : EmbedderException
      {
          public int ByteCount { get; }
          public MisalignedByteCount(int byteCount)
              : base($"Embedding byte count {byteCount} is not a multiple of 4.") => ByteCount = byteCount;
      }
  ```

- [ ] **Step 3: Run — must fail (EmbeddingVector type does not exist).**
  ```bash
  dotnet test windows/AINotebook.sln --filter "FullyQualifiedName~EmbeddingVectorTests"
  ```
  **Expected: FAIL** (build error — `EmbeddingVector` undefined).

- [ ] **Step 4: Implement `EmbeddingVector` + `StoredEmbedding`.**
  Create `windows/src/AINotebook.Core/Models/EmbeddingVector.cs`. Use `MemoryMarshal.AsBytes` for the raw copy and reverse byte order on big-endian hosts so the on-disk layout is always little-endian (matching Apple's `Data(buffer:)` which is little-endian on Apple silicon/Intel).
  ```csharp
  using System.Runtime.InteropServices;

  namespace AINotebook.Core.Models;

  /// <summary>
  /// A float32 embedding vector. ToBytes/FromBytes reproduce Swift
  /// EmbeddingVector.asData()/init(data:) exactly: a raw contiguous little-endian
  /// IEEE-754 float32 blob with no header, no length prefix, and no dimension field.
  /// byte_count == Dim * 4; FromBytes requires byte_count % 4 == 0.
  /// </summary>
  public sealed class EmbeddingVector : IEquatable<EmbeddingVector>
  {
      public float[] Values { get; }

      public int Dim => Values.Length;

      public EmbeddingVector(float[] values)
      {
          Values = values ?? throw new ArgumentNullException(nameof(values));
      }

      public byte[] ToBytes()
      {
          var bytes = new byte[Values.Length * sizeof(float)];
          MemoryMarshal.AsBytes(Values.AsSpan()).CopyTo(bytes);
          if (!BitConverter.IsLittleEndian)
          {
              for (int i = 0; i < bytes.Length; i += sizeof(float))
                  Array.Reverse(bytes, i, sizeof(float));
          }
          return bytes;
      }

      public static EmbeddingVector FromBytes(byte[] data)
      {
          if (data is null) throw new ArgumentNullException(nameof(data));
          if (data.Length % sizeof(float) != 0)
              throw new EmbedderException.MisalignedByteCount(data.Length);

          int count = data.Length / sizeof(float);
          var values = new float[count];

          if (BitConverter.IsLittleEndian)
          {
              MemoryMarshal.Cast<byte, float>(data).CopyTo(values);
          }
          else
          {
              for (int i = 0; i < count; i++)
              {
                  int offset = i * sizeof(float);
                  values[i] = BitConverter.Int32BitsToSingle(
                      BitConverter.ToInt32(new[]
                      {
                          data[offset + 3], data[offset + 2], data[offset + 1], data[offset]
                      }, 0));
              }
          }

          return new EmbeddingVector(values);
      }

      public bool Equals(EmbeddingVector? other) =>
          other is not null && Values.AsSpan().SequenceEqual(other.Values);

      public override bool Equals(object? obj) => Equals(obj as EmbeddingVector);

      public override int GetHashCode()
      {
          var hash = new HashCode();
          foreach (var v in Values) hash.Add(v);
          return hash.ToHashCode();
      }
  }

  public record StoredEmbedding(
      long ChunkId,
      long SourceId,
      EmbeddingVector Vector);
  ```

- [ ] **Step 5: Run the tests.**
  ```bash
  dotnet test windows/AINotebook.sln --filter "FullyQualifiedName~EmbeddingVectorTests"
  ```
  **Expected: PASS** (5 passed).

- [ ] **Step 6: Commit.**
  ```bash
  git add windows/src/AINotebook.Core/Models/EmbeddingVector.cs windows/src/AINotebook.Core/Errors.cs \
          windows/tests/AINotebook.Core.Tests/Models/EmbeddingVectorTests.cs
  git commit -m "$(cat <<'EOF'
  feat(core): EmbeddingVector raw little-endian float32 encode/decode

  ToBytes/FromBytes port Swift EmbeddingVector.asData()/init(data:) 1:1 — raw
  contiguous little-endian float32 blob, no header/length/dim field, byte_count =
  Dim*4, misaligned (non-multiple-of-4) input throws. Big-endian hosts reverse
  byte order so the on-disk layout is always little-endian. Adds StoredEmbedding.
  Verbatim testsToPort assertions.

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

---

Notes for downstream writers (B/C/D): Task 2 already defines all model records/enums and the cross-cutting `StoreException`/`EmbedderException` in `windows/src/AINotebook.Core/Errors.cs` (the `ExtractorException`/`IngestionException`/`OllamaException`/`TransformationException` families are defined later beside their consuming code); Task 3 provides `AINotebook.Core.Storage.SqliteDate`; Task 4 provides `EmbeddingVector`/`StoredEmbedding` and adds `EmbedderException.MisalignedByteCount`. The `windows/tests/AINotebook.Core.Tests/Helpers/StubHttpMessageHandler.cs` helper is owned by the Ollama task writer.

---

## Task 5 — Migrator + the 9 versioned migrations

**Files:**
- Create: `windows/src/AINotebook.Core/Storage/Migrator.cs`
- Test: `windows/tests/AINotebook.Core.Tests/Storage/MigratorTests.cs`
- (`SqliteDate` is defined in Task 3 — used here, not recreated.)

Migrations are tracked in a `grdb_migrations(identifier TEXT NOT NULL PRIMARY KEY)` table (faithful to GRDB — no `PRAGMA user_version`). A migration is applied iff its identifier string is present. The 9 identifiers, **in order**, are: `v1_notebooks`, `v2_sources_and_chunks`, `v3_chunk_embeddings`, `v4_chat_sessions_and_messages`, `v5_notes_and_transformations`, `v6_notes_auto_source_and_uuid`, `v7_attachments`, `v8_note_versions`, `v9_transformations_description`. Each migration's body runs inside a transaction, then the identifier is inserted. `PRAGMA foreign_keys=ON` must be enabled on every connection (the cascade tests depend on it). The verbatim DDL below was captured from the live production DB (`sqlite3 .schema`) — reproduce it exactly. Cite: `Sources/AINotebookCore/MigrationV1.swift`…`MigrationV9.swift`.

- [ ] **Step 1: `SqliteDate` already exists (defined in Task 3).** This task USES `AINotebook.Core.Storage.SqliteDate` (TEXT `yyyy-MM-dd HH:mm:ss.fff`, UTC, with the numeric unix-epoch fallback merged in Task 3). Do NOT recreate it here — just `using AINotebook.Core.Storage;` where needed.

- [ ] **Step 2: Write failing tests for migration tracking + v1/v2 schema.** Create `windows/tests/AINotebook.Core.Tests/Storage/MigratorTests.cs`:

```csharp
using AINotebook.Core.Storage;
using Microsoft.Data.Sqlite;
using Xunit;

namespace AINotebook.Core.Tests.Storage;

public class MigratorTests
{
    private static SqliteConnection OpenMigrated()
    {
        var conn = new SqliteConnection("Data Source=:memory:");
        conn.Open();
        using (var pragma = conn.CreateCommand())
        {
            pragma.CommandText = "PRAGMA foreign_keys=ON";
            pragma.ExecuteNonQuery();
        }
        Migrator.Migrate(conn);
        return conn;
    }

    private static List<string> Tables(SqliteConnection c, string type = "table")
    {
        using var cmd = c.CreateCommand();
        cmd.CommandText = "SELECT name FROM sqlite_master WHERE type=$t ORDER BY name";
        cmd.Parameters.AddWithValue("$t", type);
        var list = new List<string>();
        using var r = cmd.ExecuteReader();
        while (r.Read()) list.Add(r.GetString(0));
        return list;
    }

    private static List<string> Columns(SqliteConnection c, string table)
    {
        using var cmd = c.CreateCommand();
        cmd.CommandText = $"SELECT name FROM pragma_table_info('{table}') ORDER BY name";
        var list = new List<string>();
        using var r = cmd.ExecuteReader();
        while (r.Read()) list.Add(r.GetString(0));
        return list;
    }

    [Fact]
    public void TracksAllNineIdentifiersInOrder()
    {
        using var c = OpenMigrated();
        using var cmd = c.CreateCommand();
        cmd.CommandText = "SELECT identifier FROM grdb_migrations ORDER BY rowid";
        var ids = new List<string>();
        using var r = cmd.ExecuteReader();
        while (r.Read()) ids.Add(r.GetString(0));
        Assert.Equal(new[]
        {
            "v1_notebooks", "v2_sources_and_chunks", "v3_chunk_embeddings",
            "v4_chat_sessions_and_messages", "v5_notes_and_transformations",
            "v6_notes_auto_source_and_uuid", "v7_attachments",
            "v8_note_versions", "v9_transformations_description"
        }, ids);
    }

    [Fact]
    public void MigrateIsIdempotent()
    {
        using var c = OpenMigrated();
        Migrator.Migrate(c); // second run is a no-op
        using var cmd = c.CreateCommand();
        cmd.CommandText = "SELECT count(*) FROM grdb_migrations";
        Assert.Equal(9L, (long)cmd.ExecuteScalar()!);
    }

    [Fact]
    public void V1_NotebooksColumnsSorted()
    {
        using var c = OpenMigrated();
        Assert.Contains("notebooks", Tables(c));
        Assert.Equal(
            new[] { "created_at", "description", "id", "name", "updated_at" },
            Columns(c, "notebooks"));
    }

    [Fact]
    public void V1_NameIndexExists()
    {
        using var c = OpenMigrated();
        Assert.Contains("notebooks_name_idx", Tables(c, "index"));
    }

    [Fact]
    public void V2_CreatesAllExpectedTablesAndIndexes()
    {
        using var c = OpenMigrated();
        var tables = Tables(c);
        Assert.Contains("sources", tables);
        Assert.Contains("source_chunks", tables);
        Assert.Contains("sources_fts", tables);
        Assert.Contains("chunks_fts", tables);
        var idx = Tables(c, "index");
        Assert.Contains("idx_sources_notebook", idx);
        Assert.Contains("idx_chunks_source", idx);
    }

    [Fact]
    public void V2_SourcesFtsKeepsInSyncWithSources()
    {
        using var c = OpenMigrated();
        using (var nb = c.CreateCommand())
        {
            nb.CommandText =
                "INSERT INTO notebooks(name,description,created_at,updated_at) VALUES('n','','2026-01-01 00:00:00.000','2026-01-01 00:00:00.000')";
            nb.ExecuteNonQuery();
        }
        using (var src = c.CreateCommand())
        {
            src.CommandText =
                "INSERT INTO sources(notebook_id,type,title,status,ingested_at) VALUES(1,'text','Hello world','pending','2026-01-01 00:00:00.000')";
            src.ExecuteNonQuery();
        }
        using var q = c.CreateCommand();
        q.CommandText = "SELECT count(*) FROM sources_fts WHERE sources_fts MATCH 'hello'";
        Assert.Equal(1L, (long)q.ExecuteScalar()!);
    }
}
```

- [ ] **Step 3: Run the tests — Expected: FAIL (Migrator does not exist).**

```
dotnet test windows/tests/AINotebook.Core.Tests --filter "FullyQualifiedName~MigratorTests"
```

Expected: FAIL (compile error: `Migrator` not found).

- [ ] **Step 4: Implement the Migrator with all 9 verbatim DDL migrations.** Create `windows/src/AINotebook.Core/Storage/Migrator.cs`:

```csharp
using System.Globalization;
using Microsoft.Data.Sqlite;

namespace AINotebook.Core.Storage;

/// <summary>
/// Runs the 9 versioned migrations, tracked by identifier string in
/// grdb_migrations(identifier TEXT PK) — faithful to GRDB DatabaseMigrator.
/// DDL is verbatim from the live production DB schema.
/// </summary>
public static class Migrator
{
    private static readonly (string Id, string Sql)[] Migrations =
    {
        ("v1_notebooks", V1),
        ("v2_sources_and_chunks", V2),
        ("v3_chunk_embeddings", V3),
        ("v4_chat_sessions_and_messages", V4),
        ("v5_notes_and_transformations", V5),
        ("v6_notes_auto_source_and_uuid", V6),
        ("v7_attachments", V7),
        ("v8_note_versions", V8),
        ("v9_transformations_description", V9),
    };

    public static void Migrate(SqliteConnection conn)
    {
        EnsureTrackingTable(conn);
        var applied = AppliedIdentifiers(conn);
        foreach (var (id, sql) in Migrations)
        {
            if (applied.Contains(id)) continue;
            using var tx = conn.BeginTransaction();
            foreach (var stmt in SplitStatements(sql))
            {
                using var cmd = conn.CreateCommand();
                cmd.Transaction = tx;
                cmd.CommandText = stmt;
                cmd.ExecuteNonQuery();
            }
            RunCustom(conn, tx, id);
            using (var ins = conn.CreateCommand())
            {
                ins.Transaction = tx;
                ins.CommandText = "INSERT INTO grdb_migrations(identifier) VALUES($id)";
                ins.Parameters.AddWithValue("$id", id);
                ins.ExecuteNonQuery();
            }
            tx.Commit();
        }
    }

    private static void EnsureTrackingTable(SqliteConnection conn)
    {
        using var cmd = conn.CreateCommand();
        cmd.CommandText =
            "CREATE TABLE IF NOT EXISTS grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)";
        cmd.ExecuteNonQuery();
    }

    private static HashSet<string> AppliedIdentifiers(SqliteConnection conn)
    {
        var set = new HashSet<string>(StringComparer.Ordinal);
        using var cmd = conn.CreateCommand();
        cmd.CommandText = "SELECT identifier FROM grdb_migrations";
        using var r = cmd.ExecuteReader();
        while (r.Read()) set.Add(r.GetString(0));
        return set;
    }

    /// <summary>
    /// Splits a migration body into individual statements on the literal
    /// "@@" separator we use between DDL statements (so CREATE TRIGGER bodies
    /// with embedded ';' are not broken apart).
    /// </summary>
    private static IEnumerable<string> SplitStatements(string sql)
    {
        foreach (var part in sql.Split("@@", StringSplitOptions.RemoveEmptyEntries))
        {
            var trimmed = part.Trim();
            if (trimmed.Length > 0) yield return trimmed;
        }
    }

    /// <summary>v6 backfills note_uuid for any pre-existing NULL rows.</summary>
    private static void RunCustom(SqliteConnection conn, SqliteTransaction tx, string id)
    {
        if (id != "v6_notes_auto_source_and_uuid") return;
        var ids = new List<long>();
        using (var sel = conn.CreateCommand())
        {
            sel.Transaction = tx;
            sel.CommandText = "SELECT id FROM notes WHERE note_uuid IS NULL";
            using var r = sel.ExecuteReader();
            while (r.Read()) ids.Add(r.GetInt64(0));
        }
        foreach (var noteId in ids)
        {
            using var upd = conn.CreateCommand();
            upd.Transaction = tx;
            upd.CommandText = "UPDATE notes SET note_uuid = $u WHERE id = $id";
            upd.Parameters.AddWithValue("$u", Guid.NewGuid().ToString().ToLowerInvariant());
            upd.Parameters.AddWithValue("$id", noteId);
            upd.ExecuteNonQuery();
        }
    }

    private const string V1 = """
        CREATE TABLE IF NOT EXISTS "notebooks" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "name" TEXT NOT NULL, "description" TEXT NOT NULL DEFAULT '', "created_at" DATETIME NOT NULL, "updated_at" DATETIME NOT NULL);
        @@
        CREATE INDEX "notebooks_name_idx" ON "notebooks"("name");
        """;

    private const string V2 = """
        CREATE TABLE IF NOT EXISTS "sources" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "notebook_id" INTEGER NOT NULL REFERENCES "notebooks"("id") ON DELETE CASCADE, "type" TEXT NOT NULL, "title" TEXT NOT NULL, "uri" TEXT, "raw_path" TEXT, "status" TEXT NOT NULL, "error" TEXT, "ingested_at" DATETIME NOT NULL);
        @@
        CREATE INDEX "idx_sources_notebook" ON "sources"("notebook_id");
        @@
        CREATE TABLE IF NOT EXISTS "source_chunks" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "source_id" INTEGER NOT NULL REFERENCES "sources"("id") ON DELETE CASCADE, "ord" INTEGER NOT NULL, "text" TEXT NOT NULL, "token_count" INTEGER NOT NULL, "page_hint" INTEGER);
        @@
        CREATE INDEX "idx_chunks_source" ON "source_chunks"("source_id", "ord");
        @@
        CREATE VIRTUAL TABLE sources_fts USING fts5(title, source_id UNINDEXED, tokenize = 'porter unicode61');
        @@
        CREATE VIRTUAL TABLE chunks_fts USING fts5(text, chunk_id UNINDEXED, tokenize = 'porter unicode61');
        @@
        CREATE TRIGGER sources_ai AFTER INSERT ON sources BEGIN
          INSERT INTO sources_fts(rowid, title, source_id) VALUES (new.id, new.title, new.id);
        END;
        @@
        CREATE TRIGGER sources_ad AFTER DELETE ON sources BEGIN
          DELETE FROM sources_fts WHERE rowid = old.id;
        END;
        @@
        CREATE TRIGGER sources_au AFTER UPDATE ON sources BEGIN
          UPDATE sources_fts SET title = new.title WHERE rowid = old.id;
        END;
        @@
        CREATE TRIGGER chunks_ai AFTER INSERT ON source_chunks BEGIN
          INSERT INTO chunks_fts(rowid, text, chunk_id) VALUES (new.id, new.text, new.id);
        END;
        @@
        CREATE TRIGGER chunks_ad AFTER DELETE ON source_chunks BEGIN
          DELETE FROM chunks_fts WHERE rowid = old.id;
        END;
        @@
        CREATE TRIGGER chunks_au AFTER UPDATE ON source_chunks BEGIN
          UPDATE chunks_fts SET text = new.text WHERE rowid = old.id;
        END;
        """;

    private const string V3 = """
        CREATE TABLE IF NOT EXISTS "chunk_embeddings" ("chunk_id" INTEGER PRIMARY KEY REFERENCES "source_chunks"("id") ON DELETE CASCADE, "dim" INTEGER NOT NULL, "model" TEXT NOT NULL, "embedding" BLOB NOT NULL);
        @@
        CREATE INDEX "idx_chunk_embeddings_model" ON "chunk_embeddings"("model");
        """;

    private const string V4 = """
        CREATE TABLE IF NOT EXISTS "chat_sessions" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "notebook_id" INTEGER NOT NULL REFERENCES "notebooks"("id") ON DELETE CASCADE, "title" TEXT NOT NULL, "created_at" DATETIME NOT NULL);
        @@
        CREATE INDEX "idx_chat_sessions_notebook" ON "chat_sessions"("notebook_id", "created_at");
        @@
        CREATE TABLE IF NOT EXISTS "messages" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "session_id" INTEGER NOT NULL REFERENCES "chat_sessions"("id") ON DELETE CASCADE, "role" TEXT NOT NULL, "content" TEXT NOT NULL, "citations_json" TEXT, "created_at" DATETIME NOT NULL);
        @@
        CREATE INDEX "idx_messages_session" ON "messages"("session_id", "created_at");
        """;

    private const string V5 = """
        CREATE TABLE IF NOT EXISTS "notes" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "notebook_id" INTEGER NOT NULL REFERENCES "notebooks"("id") ON DELETE CASCADE, "title" TEXT NOT NULL, "body_md" TEXT NOT NULL, "origin" TEXT NOT NULL, "origin_ref" INTEGER, "created_at" DATETIME NOT NULL, "updated_at" DATETIME NOT NULL);
        @@
        CREATE INDEX "idx_notes_notebook" ON "notes"("notebook_id", "updated_at");
        @@
        CREATE TABLE IF NOT EXISTS "transformations" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "name" TEXT NOT NULL, "prompt_template" TEXT NOT NULL, "scope" TEXT NOT NULL, "is_builtin" INTEGER NOT NULL DEFAULT 0);
        @@
        CREATE INDEX "idx_transformations_name" ON "transformations"("name");
        @@
        CREATE TABLE IF NOT EXISTS "transformation_runs" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "transformation_id" INTEGER NOT NULL REFERENCES "transformations"("id") ON DELETE CASCADE, "source_id" INTEGER REFERENCES "sources"("id") ON DELETE SET NULL, "result_note_id" INTEGER REFERENCES "notes"("id") ON DELETE SET NULL, "ran_at" DATETIME NOT NULL);
        """;

    private const string V6 = """
        ALTER TABLE notes ADD COLUMN "auto_source_id" INTEGER REFERENCES "sources"("id") ON DELETE SET NULL;
        @@
        ALTER TABLE notes ADD COLUMN "note_uuid" TEXT;
        @@
        CREATE INDEX "idx_notes_auto_source" ON "notes"("auto_source_id");
        """;

    private const string V7 = """
        CREATE TABLE IF NOT EXISTS "attachments" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "note_id" INTEGER NOT NULL REFERENCES "notes"("id") ON DELETE CASCADE, "note_uuid" TEXT NOT NULL, "filename" TEXT NOT NULL, "mime" TEXT NOT NULL, "byte_size" INTEGER NOT NULL, "created_at" DATETIME NOT NULL);
        @@
        CREATE INDEX "idx_attachments_note" ON "attachments"("note_id");
        """;

    private const string V8 = """
        CREATE TABLE IF NOT EXISTS "note_versions" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "note_id" INTEGER NOT NULL REFERENCES "notes"("id") ON DELETE CASCADE, "title" TEXT NOT NULL, "body_md" TEXT NOT NULL, "saved_at" DATETIME NOT NULL, "reason" TEXT NOT NULL);
        @@
        CREATE INDEX "idx_note_versions_note" ON "note_versions"("note_id", "saved_at");
        """;

    private const string V9 = """
        ALTER TABLE transformations ADD COLUMN "description" TEXT NOT NULL DEFAULT '';
        """;
}
```

- [ ] **Step 5: Run the tests — Expected: PASS.**

```
dotnet test windows/tests/AINotebook.Core.Tests --filter "FullyQualifiedName~MigratorTests"
```

Expected: PASS (7 tests).

- [ ] **Step 6: Add the per-migration cascade/column tests (v3, v6, v7, v8, v9).** Append to `MigratorTests.cs`:

```csharp
    private static void SeedNotebook(SqliteConnection c) =>
        Exec(c, "INSERT INTO notebooks(name,description,created_at,updated_at) VALUES('n','','2026-01-01 00:00:00.000','2026-01-01 00:00:00.000')");

    private static void Exec(SqliteConnection c, string sql)
    {
        using var cmd = c.CreateCommand();
        cmd.CommandText = sql;
        cmd.ExecuteNonQuery();
    }

    private static long Count(SqliteConnection c, string table)
    {
        using var cmd = c.CreateCommand();
        cmd.CommandText = $"SELECT count(*) FROM {table}";
        return (long)cmd.ExecuteScalar()!;
    }

    [Fact]
    public void V3_CreatesChunkEmbeddingsTable()
    {
        using var c = OpenMigrated();
        Assert.Contains("chunk_embeddings", Tables(c));
    }

    [Fact]
    public void V3_CascadeDeleteWhenSourceDeleted_RequiresForeignKeysOn()
    {
        using var c = OpenMigrated();
        SeedNotebook(c);
        Exec(c, "INSERT INTO sources(notebook_id,type,title,status,ingested_at) VALUES(1,'text','t','ready','2026-01-01 00:00:00.000')");
        Exec(c, "INSERT INTO source_chunks(source_id,ord,text,token_count) VALUES(1,0,'x',1)");
        Exec(c, "INSERT INTO chunk_embeddings(chunk_id,dim,model,embedding) VALUES(1,4,'m',zeroblob(16))");
        Exec(c, "DELETE FROM sources WHERE id=1");
        Assert.Equal(0L, Count(c, "source_chunks"));
        Assert.Equal(0L, Count(c, "chunk_embeddings"));
    }

    [Fact]
    public void V6_AddsColumnsToNotes()
    {
        using var c = OpenMigrated();
        var cols = Columns(c, "notes");
        Assert.Contains("auto_source_id", cols);
        Assert.Contains("note_uuid", cols);
    }

    [Fact]
    public void V7_AttachmentsCascadeOnNoteDelete()
    {
        using var c = OpenMigrated();
        SeedNotebook(c);
        Exec(c, "INSERT INTO notes(notebook_id,title,body_md,origin,note_uuid,created_at,updated_at) VALUES(1,'t','b','manual','11111111-1111-1111-1111-111111111111','2026-01-01 00:00:00.000','2026-01-01 00:00:00.000')");
        Exec(c, "INSERT INTO attachments(note_id,note_uuid,filename,mime,byte_size,created_at) VALUES(1,'11111111-1111-1111-1111-111111111111','a.png','image/png',3,'2026-01-01 00:00:00.000')");
        Exec(c, "DELETE FROM notes WHERE id=1");
        Assert.Equal(0L, Count(c, "attachments"));
    }

    [Fact]
    public void V8_NoteVersionsCascadeOnNoteDelete()
    {
        using var c = OpenMigrated();
        SeedNotebook(c);
        Exec(c, "INSERT INTO notes(notebook_id,title,body_md,origin,note_uuid,created_at,updated_at) VALUES(1,'t','b','manual','22222222-2222-2222-2222-222222222222','2026-01-01 00:00:00.000','2026-01-01 00:00:00.000')");
        Exec(c, "INSERT INTO note_versions(note_id,title,body_md,saved_at,reason) VALUES(1,'t','b','2026-01-01 00:00:00.000','autosave')");
        Exec(c, "DELETE FROM notes WHERE id=1");
        Assert.Equal(0L, Count(c, "note_versions"));
    }

    [Fact]
    public void V9_ExistingRowsGetEmptyStringDefault()
    {
        using var c = OpenMigrated();
        Exec(c, "INSERT INTO transformations(name,prompt_template,scope,is_builtin) VALUES('x','{{source_text}}','source',0)");
        Assert.Contains("description", Columns(c, "transformations"));
        using var cmd = c.CreateCommand();
        cmd.CommandText = "SELECT description FROM transformations WHERE name='x'";
        Assert.Equal("", (string)cmd.ExecuteScalar()!);
    }
```

- [ ] **Step 7: Run — Expected: PASS.**

```
dotnet test windows/tests/AINotebook.Core.Tests --filter "FullyQualifiedName~MigratorTests"
```

Expected: PASS (13 tests).

- [ ] **Step 8: Commit.**

```
git add windows/src/AINotebook.Core/Storage/Migrator.cs windows/tests/AINotebook.Core.Tests/Storage/MigratorTests.cs
git commit -m "feat(core): Migrator + 9 versioned migrations (verbatim DDL, FTS5, FK cascades)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6 — NotebookStore connection management + notebooks CRUD

**Files:**
- Create: `windows/src/AINotebook.Core/Storage/StorePath.cs`
- Create: `windows/src/AINotebook.Core/Storage/NotebookStore.cs`
- Test: `windows/tests/AINotebook.Core.Tests/Storage/NotebookStoreTests.cs`

`NotebookStore` opens one Microsoft.Data.Sqlite connection (in-memory keeps a single connection open for the store's lifetime; production opens the file DB), runs `PRAGMA foreign_keys=ON`, runs the `Migrator`, seeds builtins (wired in Task 11), and exposes CRUD. Notebooks are listed ordered by `updated_at DESC`. Names are trimmed; empty trimmed name → `InvalidNotebookName`. Rename bumps `updated_at`; unknown id → `NotebookNotFound`. Cite: `Sources/AINotebookCore/NotebookStore.swift`.

- [ ] **Step 1: Write failing tests.** Create `windows/tests/AINotebook.Core.Tests/Storage/NotebookStoreTests.cs`:

```csharp
using AINotebook.Core;
using AINotebook.Core.Storage;
using Xunit;

namespace AINotebook.Core.Tests.Storage;

public class NotebookStoreTests
{
    [Fact]
    public void CreateTrimsNameAndAppends()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("  Research  ");
        Assert.Equal("Research", nb.Name);
        Assert.NotNull(nb.Id);
    }

    [Fact]
    public void CreateRejectsEmptyName()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        var ex = Assert.Throws<StoreException.InvalidNotebookName>(
            () => store.CreateNotebook("   "));
        Assert.Equal("   ", ex.Name);
    }

    [Fact]
    public void ListIsOrderedByUpdatedAtDescAndRenameResortsToTop()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        var a = store.CreateNotebook("A");
        var b = store.CreateNotebook("B");
        // b is newest -> first
        Assert.Equal(new[] { "B", "A" }, store.Notebooks().Select(n => n.Name).ToArray());
        store.RenameNotebook(a.Id!.Value, "A2");
        Assert.Equal(new[] { "A2", "B" }, store.Notebooks().Select(n => n.Name).ToArray());
    }

    [Fact]
    public void RenameBumpsUpdatedAtAndRejectsEmptyAndUnknown()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        var a = store.CreateNotebook("A");
        var before = a.UpdatedAt;
        var renamed = store.RenameNotebook(a.Id!.Value, "  A2 ");
        Assert.Equal("A2", renamed.Name);
        Assert.True(renamed.UpdatedAt >= before);
        Assert.Throws<StoreException.InvalidNotebookName>(
            () => store.RenameNotebook(a.Id!.Value, " "));
        Assert.Throws<StoreException.NotebookNotFound>(
            () => store.RenameNotebook(99999, "x"));
    }

    [Fact]
    public void DeleteRemovesAndUnknownThrows()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        var a = store.CreateNotebook("A");
        store.DeleteNotebook(a.Id!.Value);
        Assert.Empty(store.Notebooks());
        Assert.Throws<StoreException.NotebookNotFound>(() => store.DeleteNotebook(a.Id!.Value));
    }

    [Fact]
    public void PersistsAcrossReopenedStoreInstances()
    {
        var dir = Path.Combine(Path.GetTempPath(), "ainb-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        var path = new StorePath(Path.Combine(dir, "db.sqlite"));
        try
        {
            using (var store = new NotebookStore(path))
                store.CreateNotebook("Persisted");
            using (var reopened = new NotebookStore(path))
                Assert.Equal("Persisted", reopened.Notebooks().Single().Name);
        }
        finally { Directory.Delete(dir, recursive: true); }
    }
}
```

- [ ] **Step 2: Run — Expected: FAIL (`NotebookStore`/`StorePath` not found).**

```
dotnet test windows/tests/AINotebook.Core.Tests --filter "FullyQualifiedName~NotebookStoreTests"
```

Expected: FAIL.

- [ ] **Step 3: Implement StorePath.** Create `windows/src/AINotebook.Core/Storage/StorePath.cs`:

```csharp
namespace AINotebook.Core.Storage;

/// <summary>
/// Where the SQLite database lives. Either an on-disk file path or the
/// in-memory marker (FilePath == null) for tests.
/// </summary>
public sealed class StorePath
{
    public string? FilePath { get; }
    public bool IsInMemory => FilePath is null;

    public StorePath(string? filePath) => FilePath = filePath;

    public static StorePath InMemory => new(null);

    /// <summary>
    /// %APPDATA%\AINotebook\db.sqlite, creating the parent directory on demand.
    /// </summary>
    public static StorePath Production()
    {
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        var container = Path.Combine(appData, "AINotebook");
        Directory.CreateDirectory(container);
        return new StorePath(Path.Combine(container, "db.sqlite"));
    }
}
```

- [ ] **Step 4: Implement NotebookStore (connection + notebooks CRUD).** Create `windows/src/AINotebook.Core/Storage/NotebookStore.cs`:

```csharp
using AINotebook.Core.Models;
using Dapper;
using Microsoft.Data.Sqlite;

namespace AINotebook.Core.Storage;

/// <summary>
/// Owns the SQLite connection and exposes CRUD. In-memory uses one kept-open
/// connection for the store lifetime; production opens the file DB. Runs
/// PRAGMA foreign_keys=ON, the Migrator, and seeds builtin transformations.
/// </summary>
public sealed partial class NotebookStore : IDisposable
{
    private readonly SqliteConnection _conn;
    private readonly AppLanguage _language;

    /// <summary>Fires after createNote/updateNote with the affected note id.</summary>
    public Func<long, Task>? OnNoteSaved { get; set; }

    /// <summary>Fires after a note is deleted, with the note's UUID.</summary>
    public Func<string, Task>? OnNoteDeleted { get; set; }

    public NotebookStore(StorePath path, AppLanguage language = AppLanguage.English)
    {
        _language = language;
        var connStr = path.IsInMemory
            ? "Data Source=InMemoryAINotebook;Mode=Memory;Cache=Shared"
            : $"Data Source={path.FilePath}";
        _conn = new SqliteConnection(connStr);
        _conn.Open();
        Execute("PRAGMA foreign_keys=ON");
        Migrator.Migrate(_conn);
        BuiltinTransformations.SeedIfNeeded(_conn, _language);
    }

    /// <summary>Test/internal affordance: access the open connection.</summary>
    internal SqliteConnection Connection => _conn;

    private int Execute(string sql, object? param = null) => _conn.Execute(sql, param);

    public void Dispose() => _conn.Dispose();

    // ---- Notebooks ----

    public Notebook CreateNotebook(string name, string description = "")
    {
        var trimmed = name.Trim();
        if (trimmed.Length == 0) throw new StoreException.InvalidNotebookName(name);
        var now = DateTime.UtcNow;
        var id = _conn.ExecuteScalar<long>(
            """
            INSERT INTO notebooks(name, description, created_at, updated_at)
            VALUES($name, $desc, $created, $updated);
            SELECT last_insert_rowid();
            """,
            new { name = trimmed, desc = description, created = SqliteDate.ToDb(now), updated = SqliteDate.ToDb(now) });
        return new Notebook(id, trimmed, description, now, now);
    }

    public IReadOnlyList<Notebook> Notebooks()
    {
        return _conn.Query(
            "SELECT id, name, description, created_at, updated_at FROM notebooks ORDER BY updated_at DESC")
            .Select(r => new Notebook(
                (long)r.id, (string)r.name, (string)r.description,
                SqliteDate.FromDb((string)r.created_at), SqliteDate.FromDb((string)r.updated_at)))
            .ToList();
    }

    public Notebook RenameNotebook(long id, string newName)
    {
        var trimmed = newName.Trim();
        if (trimmed.Length == 0) throw new StoreException.InvalidNotebookName(newName);
        var now = DateTime.UtcNow;
        var rows = _conn.Execute(
            "UPDATE notebooks SET name=$name, updated_at=$updated WHERE id=$id",
            new { name = trimmed, updated = SqliteDate.ToDb(now), id });
        if (rows == 0) throw new StoreException.NotebookNotFound(id);
        var row = _conn.QuerySingle(
            "SELECT id, name, description, created_at, updated_at FROM notebooks WHERE id=$id", new { id });
        return new Notebook((long)row.id, (string)row.name, (string)row.description,
            SqliteDate.FromDb((string)row.created_at), SqliteDate.FromDb((string)row.updated_at));
    }

    public void DeleteNotebook(long id)
    {
        var rows = _conn.Execute("DELETE FROM notebooks WHERE id=$id", new { id });
        if (rows == 0) throw new StoreException.NotebookNotFound(id);
    }
}
```

> NOTE: `NotebookStore` is declared `partial`; Tasks 7–11 add the Sources/Embeddings/Chat/Notes/Transformations members in separate `NotebookStore.*.cs` files. `BuiltinTransformations.SeedIfNeeded` is implemented in Task 11 — until then, add a temporary empty stub `internal static class BuiltinTransformations { internal static void SeedIfNeeded(SqliteConnection c, AppLanguage l) {} }` in this file's namespace so it compiles, and replace it in Task 11.

- [ ] **Step 5: Run — Expected: PASS.**

```
dotnet test windows/tests/AINotebook.Core.Tests --filter "FullyQualifiedName~NotebookStoreTests"
```

Expected: PASS (6 tests).

- [ ] **Step 6: Commit.**

```
git add windows/src/AINotebook.Core/Storage/StorePath.cs windows/src/AINotebook.Core/Storage/NotebookStore.cs windows/tests/AINotebook.Core.Tests/Storage/NotebookStoreTests.cs
git commit -m "feat(core): NotebookStore connection mgmt + notebooks CRUD

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 7 — Sources CRUD + ReplaceChunks + shadow filtering

**Files:**
- Create: `windows/src/AINotebook.Core/Storage/NotebookStore.Sources.cs`
- Test: `windows/tests/AINotebook.Core.Tests/Storage/NotebookStoreSourcesTests.cs`

`CreateSource` trims the title (empty → `InvalidSourceTitle`), inserts with status `Pending`. `UpdateSourceStatus` persists status+error (unknown id → `SourceNotFound`). `UpdateSourceTitle` renames a source; the `sources_au` FTS trigger keeps `sources_fts` in sync (used by `NoteIndexer` in Task 25). `ReplaceChunks` deletes all chunks for the source then re-inserts with `ord` = 0-based index inside a single transaction; the FTS triggers keep `chunks_fts` in sync automatically. `Sources()` excludes `type='note'` shadow rows; `SourcesIncludingShadow()` includes them. `DeleteSource` cascades to chunks (FK). Cite: `Sources/AINotebookCore/NotebookStore+Sources.swift`.

- [ ] **Step 1: Write failing tests.** Create `windows/tests/AINotebook.Core.Tests/Storage/NotebookStoreSourcesTests.cs`:

```csharp
using AINotebook.Core;
using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using Xunit;

namespace AINotebook.Core.Tests.Storage;

public class NotebookStoreSourcesTests
{
    private static (NotebookStore store, long nbId) Fresh()
    {
        var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("N");
        return (store, nb.Id!.Value);
    }

    [Fact]
    public void CreateSourceDefaultsToPendingAndTrimsTitle()
    {
        var (store, nb) = Fresh();
        using (store)
        {
            var s = store.CreateSource(nb, SourceType.Text, "  Doc  ", uri: null, rawPath: "/tmp/x");
            Assert.Equal(SourceStatus.Pending, s.Status);
            Assert.Equal("Doc", s.Title);
        }
    }

    [Fact]
    public void CreateSourceRejectsEmptyTitle()
    {
        var (store, nb) = Fresh();
        using (store)
            Assert.Throws<StoreException.InvalidSourceTitle>(
                () => store.CreateSource(nb, SourceType.Text, "  ", null, null));
    }

    [Fact]
    public void UpdateSourceStatusPersistsAndUnknownThrows()
    {
        var (store, nb) = Fresh();
        using (store)
        {
            var s = store.CreateSource(nb, SourceType.Pdf, "p", null, null);
            store.UpdateSourceStatus(s.Id!.Value, SourceStatus.Error, "boom");
            var reloaded = store.Source(s.Id!.Value)!;
            Assert.Equal(SourceStatus.Error, reloaded.Status);
            Assert.Equal("boom", reloaded.Error);
            Assert.Throws<StoreException.SourceNotFound>(
                () => store.UpdateSourceStatus(99999, SourceStatus.Ready, null));
        }
    }

    [Fact]
    public void UpdateSourceTitleChangesTitleAndSyncsFts()
    {
        var (store, nb) = Fresh();
        using (store)
        {
            var s = store.CreateSource(nb, SourceType.Text, "OldTitle", null, null);
            store.UpdateSourceTitle(s.Id!.Value, "BrandNewTitle");
            Assert.Equal("BrandNewTitle", store.Source(s.Id!.Value)!.Title);

            // The sources_au trigger must keep sources_fts in sync with the new title.
            using var cmd = store.Connection.CreateCommand();
            cmd.CommandText = "SELECT count(*) FROM sources_fts WHERE sources_fts MATCH $q";
            cmd.Parameters.AddWithValue("$q", "BrandNewTitle");
            Assert.Equal(1L, (long)cmd.ExecuteScalar()!);
        }
    }

    [Fact]
    public void ReplaceChunksClearsThenReinsertsWithOrdZeroToN()
    {
        var (store, nb) = Fresh();
        using (store)
        {
            var s = store.CreateSource(nb, SourceType.Text, "t", null, null);
            store.ReplaceChunks(s.Id!.Value, new[]
            {
                new ChunkDraft("first", 1, null),
                new ChunkDraft("second", 1, 2),
            });
            // Replace again with a single chunk -> old ones cleared
            store.ReplaceChunks(s.Id!.Value, new[] { new ChunkDraft("only", 1, null) });
            var chunks = store.Chunks(s.Id!.Value);
            Assert.Single(chunks);
            Assert.Equal(0, chunks[0].Ord);
            Assert.Equal("only", chunks[0].Text);
        }
    }

    [Fact]
    public void DeleteSourceCascadesChunks()
    {
        var (store, nb) = Fresh();
        using (store)
        {
            var s = store.CreateSource(nb, SourceType.Text, "t", null, null);
            store.ReplaceChunks(s.Id!.Value, new[] { new ChunkDraft("a", 1, null) });
            store.DeleteSource(s.Id!.Value);
            Assert.Empty(store.Chunks(s.Id!.Value));
            Assert.Throws<StoreException.SourceNotFound>(() => store.DeleteSource(s.Id!.Value));
        }
    }

    [Fact]
    public void SourcesExcludesShadowNotesButIncludingShadowReturnsThem()
    {
        var (store, nb) = Fresh();
        using (store)
        {
            store.CreateSource(nb, SourceType.Text, "real", null, null);
            store.CreateSource(nb, SourceType.Note, "shadow", null, null);
            Assert.Single(store.Sources(nb));
            Assert.Equal("real", store.Sources(nb).Single().Title);
            Assert.Equal(2, store.SourcesIncludingShadow(nb).Count);
        }
    }
}
```

- [ ] **Step 2: Run — Expected: FAIL.**

```
dotnet test windows/tests/AINotebook.Core.Tests --filter "FullyQualifiedName~NotebookStoreSourcesTests"
```

Expected: FAIL.

- [ ] **Step 3: Implement the Sources partial.** Create `windows/src/AINotebook.Core/Storage/NotebookStore.Sources.cs`:

```csharp
using AINotebook.Core.Models;
using Dapper;
using Microsoft.Data.Sqlite;

namespace AINotebook.Core.Storage;

public sealed partial class NotebookStore
{
    private static Source MapSource(dynamic r) => new Source(
        (long)r.id, (long)r.notebook_id,
        SourceTypeExtensions.FromDb((string)r.type), (string)r.title,
        r.uri is null ? null : (string)r.uri,
        r.raw_path is null ? null : (string)r.raw_path,
        SourceStatusExtensions.FromDb((string)r.status),
        r.error is null ? null : (string)r.error,
        SqliteDate.FromDb((string)r.ingested_at));

    public Source CreateSource(long notebookId, SourceType type, string title, string? uri, string? rawPath)
    {
        var trimmed = title.Trim();
        if (trimmed.Length == 0) throw new StoreException.InvalidSourceTitle(title);
        var now = DateTime.UtcNow;
        var id = Connection.ExecuteScalar<long>(
            """
            INSERT INTO sources(notebook_id, type, title, uri, raw_path, status, error, ingested_at)
            VALUES($nb, $type, $title, $uri, $raw, $status, NULL, $ingested);
            SELECT last_insert_rowid();
            """,
            new
            {
                nb = notebookId, type = type.ToDb(), title = trimmed, uri, raw = rawPath,
                status = SourceStatus.Pending.ToDb(), ingested = SqliteDate.ToDb(now)
            });
        return new Source(id, notebookId, type, trimmed, uri, rawPath, SourceStatus.Pending, null, now);
    }

    private const string SourceCols =
        "id, notebook_id, type, title, uri, raw_path, status, error, ingested_at";

    public IReadOnlyList<Source> Sources(long notebookId) =>
        Connection.Query(
            $"SELECT {SourceCols} FROM sources WHERE notebook_id=$nb AND type<>'note' ORDER BY ingested_at DESC",
            new { nb = notebookId })
            .Select(r => MapSource(r)).ToList();

    public IReadOnlyList<Source> SourcesIncludingShadow(long notebookId) =>
        Connection.Query(
            $"SELECT {SourceCols} FROM sources WHERE notebook_id=$nb ORDER BY ingested_at DESC",
            new { nb = notebookId })
            .Select(r => MapSource(r)).ToList();

    public Source? Source(long id)
    {
        var row = Connection.QueryFirstOrDefault(
            $"SELECT {SourceCols} FROM sources WHERE id=$id", new { id });
        return row is null ? null : MapSource(row);
    }

    public void UpdateSourceStatus(long id, SourceStatus status, string? error)
    {
        var rows = Connection.Execute(
            "UPDATE sources SET status=$status, error=$error WHERE id=$id",
            new { status = status.ToDb(), error, id });
        if (rows == 0) throw new StoreException.SourceNotFound(id);
    }

    public void UpdateSourceTitle(long id, string title)
    {
        using var cmd = Connection.CreateCommand();
        cmd.CommandText = "UPDATE sources SET title = $t WHERE id = $id";
        cmd.Parameters.AddWithValue("$t", title);
        cmd.Parameters.AddWithValue("$id", id);
        cmd.ExecuteNonQuery();
    }

    public void DeleteSource(long id)
    {
        var rows = Connection.Execute("DELETE FROM sources WHERE id=$id", new { id });
        if (rows == 0) throw new StoreException.SourceNotFound(id);
    }

    public void ReplaceChunks(long sourceId, IReadOnlyList<ChunkDraft> chunks)
    {
        using var tx = Connection.BeginTransaction();
        Connection.Execute("DELETE FROM source_chunks WHERE source_id=$sid", new { sid = sourceId }, tx);
        int ord = 0;
        foreach (var draft in chunks)
        {
            Connection.Execute(
                """
                INSERT INTO source_chunks(source_id, ord, text, token_count, page_hint)
                VALUES($sid, $ord, $text, $tc, $ph)
                """,
                new { sid = sourceId, ord, text = draft.Text, tc = draft.TokenCount, ph = draft.PageHint },
                tx);
            ord++;
        }
        tx.Commit();
    }

    public IReadOnlyList<SourceChunk> Chunks(long sourceId) =>
        Connection.Query(
            "SELECT id, source_id, ord, text, token_count, page_hint FROM source_chunks WHERE source_id=$sid ORDER BY ord ASC",
            new { sid = sourceId })
            .Select(r => new SourceChunk(
                (long)r.id, (long)r.source_id, (int)(long)r.ord, (string)r.text,
                (int)(long)r.token_count, r.page_hint is null ? (int?)null : (int)(long)r.page_hint))
            .ToList();
}
```

> NOTE: `SourceTypeExtensions.FromDb`/`.ToDb()`, `SourceStatusExtensions.FromDb`/`.ToDb()` are the enum↔string mappers from the SHARED TYPE CONTRACT (`SourceType` string values `"pdf"`,`"text"`,`"markdown"`,`"web"`,`"docx"`,`"pptx"`,`"xlsx"`,`"note"`; `SourceStatus` `"pending"`,`"chunking"`,`"ready"`,`"error"`), defined in Writer A's model files (Task 4). Use them verbatim.

- [ ] **Step 4: Run — Expected: PASS.**

```
dotnet test windows/tests/AINotebook.Core.Tests --filter "FullyQualifiedName~NotebookStoreSourcesTests"
```

Expected: PASS (7 tests).

- [ ] **Step 5: Commit.**

```
git add windows/src/AINotebook.Core/Storage/NotebookStore.Sources.cs windows/tests/AINotebook.Core.Tests/Storage/NotebookStoreSourcesTests.cs
git commit -m "feat(core): sources CRUD + ReplaceChunks (FTS-synced) + shadow filtering

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 8 — Embeddings store/query

**Files:**
- Create: `windows/src/AINotebook.Core/Storage/NotebookStore.Embeddings.cs`
- Test: `windows/tests/AINotebook.Core.Tests/Storage/NotebookStoreEmbeddingsTests.cs`

`StoreEmbedding` upserts via `ON CONFLICT(chunk_id) DO UPDATE`. The BLOB is `EmbeddingVector.ToBytes()` (raw little-endian float32, `dim*4` bytes, no header). `Embeddings(notebookId, model)` joins `chunk_embeddings → source_chunks → sources` filtering by notebook + model. `UnembeddedChunks(model, limit)` is a `LEFT JOIN … WHERE ce.chunk_id IS NULL ORDER BY sc.id ASC LIMIT`. `UnembeddedCount(model)` is the matching `count(*)`. `DeleteAllEmbeddings(model)` deletes only that model's rows. Cite: `Sources/AINotebookCore/NotebookStore+Embeddings.swift`.

- [ ] **Step 1: Write failing tests** (ported from `NotebookStoreEmbeddings` assertions). Create `windows/tests/AINotebook.Core.Tests/Storage/NotebookStoreEmbeddingsTests.cs`:

```csharp
using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using Xunit;

namespace AINotebook.Core.Tests.Storage;

public class NotebookStoreEmbeddingsTests
{
    private static (NotebookStore store, long nb, long src) Seed(int chunkCount)
    {
        var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("N").Id!.Value;
        var src = store.CreateSource(nb, SourceType.Text, "t", null, null).Id!.Value;
        var drafts = Enumerable.Range(0, chunkCount)
            .Select(i => new ChunkDraft($"chunk {i}", 1, null)).ToList();
        store.ReplaceChunks(src, drafts);
        return (store, nb, src);
    }

    [Fact]
    public void StoreAndLoadEmbedding()
    {
        var (store, nb, src) = Seed(2);
        using (store)
        {
            var chunks = store.Chunks(src);
            store.StoreEmbedding(chunks[0].Id!.Value, "m", new EmbeddingVector(new[] { 0.1f, -0.2f }));
            store.StoreEmbedding(chunks[1].Id!.Value, "m", new EmbeddingVector(new[] { 3.14f, -42.0f }));
            var loaded = store.Embeddings(nb, "m").OrderBy(e => e.ChunkId).ToList();
            Assert.Equal(2, loaded.Count);
            Assert.Equal(src, loaded[0].SourceId);
            Assert.Equal(new[] { 0.1f, -0.2f }, loaded[0].Vector.Values);
            Assert.Equal(new[] { 3.14f, -42.0f }, loaded[1].Vector.Values);
        }
    }

    [Fact]
    public void UnembeddedChunksReturnsOnlyMissingForModel()
    {
        var (store, _, src) = Seed(3);
        using (store)
        {
            var chunks = store.Chunks(src);
            store.StoreEmbedding(chunks[0].Id!.Value, "m", new EmbeddingVector(new[] { 1f }));
            var unembedded = store.UnembeddedChunks("m", 100);
            Assert.Equal(2, unembedded.Count);
            Assert.Equal(new[] { chunks[1].Id!.Value, chunks[2].Id!.Value },
                unembedded.Select(c => c.Id!.Value).ToArray());
            Assert.Equal(2, store.UnembeddedCount("m"));
        }
    }

    [Fact]
    public void ReplaceEmbeddingOverwrites()
    {
        var (store, nb, src) = Seed(1);
        using (store)
        {
            var chunkId = store.Chunks(src)[0].Id!.Value;
            store.StoreEmbedding(chunkId, "m", new EmbeddingVector(new[] { 9f, 9f }));
            store.StoreEmbedding(chunkId, "m", new EmbeddingVector(new[] { 0f, 1f }));
            var loaded = store.Embeddings(nb, "m");
            Assert.Single(loaded);
            Assert.Equal(new[] { 0f, 1f }, loaded[0].Vector.Values);
        }
    }

    [Fact]
    public void DeleteAllEmbeddingsForModelClearsOnlyThatModel()
    {
        var (store, nb, src) = Seed(1);
        using (store)
        {
            var chunkId = store.Chunks(src)[0].Id!.Value;
            store.StoreEmbedding(chunkId, "m1", new EmbeddingVector(new[] { 1f }));
            store.DeleteAllEmbeddings("m1");
            Assert.Empty(store.Embeddings(nb, "m1"));
        }
    }
}
```

- [ ] **Step 2: Run — Expected: FAIL.**

```
dotnet test windows/tests/AINotebook.Core.Tests --filter "FullyQualifiedName~NotebookStoreEmbeddingsTests"
```

Expected: FAIL.

- [ ] **Step 3: Implement the Embeddings partial.** Create `windows/src/AINotebook.Core/Storage/NotebookStore.Embeddings.cs`:

```csharp
using AINotebook.Core.Models;
using Dapper;

namespace AINotebook.Core.Storage;

public sealed partial class NotebookStore
{
    public void StoreEmbedding(long chunkId, string model, EmbeddingVector vector)
    {
        Connection.Execute(
            """
            INSERT INTO chunk_embeddings(chunk_id, dim, model, embedding)
            VALUES($cid, $dim, $model, $emb)
            ON CONFLICT(chunk_id) DO UPDATE SET
              dim = excluded.dim,
              model = excluded.model,
              embedding = excluded.embedding
            """,
            new { cid = chunkId, dim = vector.Dim, model, emb = vector.ToBytes() });
    }

    public IReadOnlyList<StoredEmbedding> Embeddings(long notebookId, string model)
    {
        return Connection.Query(
            """
            SELECT ce.chunk_id AS chunk_id, sc.source_id AS source_id, ce.embedding AS embedding
            FROM chunk_embeddings ce
            JOIN source_chunks sc ON sc.id = ce.chunk_id
            JOIN sources s ON s.id = sc.source_id
            WHERE s.notebook_id = $nb AND ce.model = $model
            """,
            new { nb = notebookId, model })
            .Select(r => new StoredEmbedding(
                (long)r.chunk_id, (long)r.source_id,
                EmbeddingVector.FromBytes((byte[])r.embedding)))
            .ToList();
    }

    public IReadOnlyList<SourceChunk> UnembeddedChunks(string model, int limit)
    {
        return Connection.Query(
            """
            SELECT sc.id AS id, sc.source_id AS source_id, sc.ord AS ord,
                   sc.text AS text, sc.token_count AS token_count, sc.page_hint AS page_hint
            FROM source_chunks sc
            LEFT JOIN chunk_embeddings ce ON ce.chunk_id = sc.id AND ce.model = $model
            WHERE ce.chunk_id IS NULL
            ORDER BY sc.id ASC
            LIMIT $limit
            """,
            new { model, limit })
            .Select(r => new SourceChunk(
                (long)r.id, (long)r.source_id, (int)(long)r.ord, (string)r.text,
                (int)(long)r.token_count, r.page_hint is null ? (int?)null : (int)(long)r.page_hint))
            .ToList();
    }

    public int UnembeddedCount(string model)
    {
        return Connection.ExecuteScalar<int>(
            """
            SELECT count(*) FROM source_chunks sc
            LEFT JOIN chunk_embeddings ce ON ce.chunk_id = sc.id AND ce.model = $model
            WHERE ce.chunk_id IS NULL
            """,
            new { model });
    }

    public void DeleteAllEmbeddings(string model) =>
        Connection.Execute("DELETE FROM chunk_embeddings WHERE model = $model", new { model });
}
```

> NOTE: `StoredEmbedding(long ChunkId, long SourceId, EmbeddingVector Vector)` and `EmbeddingVector.ToBytes()/FromBytes(byte[])` come from the SHARED TYPE CONTRACT models (Writer A, Task 4).

- [ ] **Step 4: Run — Expected: PASS.**

```
dotnet test windows/tests/AINotebook.Core.Tests --filter "FullyQualifiedName~NotebookStoreEmbeddingsTests"
```

Expected: PASS (4 tests).

- [ ] **Step 5: Commit.**

```
git add windows/src/AINotebook.Core/Storage/NotebookStore.Embeddings.cs windows/tests/AINotebook.Core.Tests/Storage/NotebookStoreEmbeddingsTests.cs
git commit -m "feat(core): embeddings store (upsert) + unembedded queries + delete-by-model

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 9 — Chat sessions + messages

**Files:**
- Create: `windows/src/AINotebook.Core/Storage/NotebookStore.Chat.cs`
- Test: `windows/tests/AINotebook.Core.Tests/Storage/NotebookStoreChatTests.cs`

`CreateChatSession` trims the title; empty trimmed → `"New chat"`. Sessions ordered `created_at DESC`. `AppendMessage` inserts a message. `Messages(sessionId)` ordered `created_at ASC`. Citations round-trip via `citations_json` — **camelCase** JSON keys (`marker`,`chunkId`,`sourceId`,`snippet`), stored as `NULL` when the citation list is empty (NOT `[]`). `DeleteChatSession` cascades messages. Cite: `Sources/AINotebookCore/NotebookStore+Chat.swift`, `ChatMessage.swift`.

- [ ] **Step 1: Write failing tests.** Create `windows/tests/AINotebook.Core.Tests/Storage/NotebookStoreChatTests.cs`:

```csharp
using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using Xunit;

namespace AINotebook.Core.Tests.Storage;

public class NotebookStoreChatTests
{
    private static (NotebookStore store, long nb) Fresh()
    {
        var store = new NotebookStore(StorePath.InMemory);
        return (store, store.CreateNotebook("N").Id!.Value);
    }

    [Fact]
    public void EmptyTitleBecomesNewChat()
    {
        var (store, nb) = Fresh();
        using (store)
            Assert.Equal("New chat", store.CreateChatSession(nb, "   ").Title);
    }

    [Fact]
    public void SessionsOrderedByCreatedAtDesc()
    {
        var (store, nb) = Fresh();
        using (store)
        {
            store.CreateChatSession(nb, "first");
            var second = store.CreateChatSession(nb, "second");
            Assert.Equal(second.Id, store.ChatSessions(nb)[0].Id);
        }
    }

    [Fact]
    public void MessagesAscendingAndCitationsRoundTrip()
    {
        var (store, nb) = Fresh();
        using (store)
        {
            var session = store.CreateChatSession(nb, "s");
            var sid = session.Id!.Value;
            store.AppendMessage(new ChatMessage(null, sid, ChatRole.User, "hi",
                Array.Empty<Citation>(), DateTime.UtcNow));
            store.AppendMessage(new ChatMessage(null, sid, ChatRole.Assistant, "answer [1]",
                new[] { new Citation(1, 42, 7, "snip") }, DateTime.UtcNow.AddMilliseconds(1)));
            var msgs = store.Messages(sid);
            Assert.Equal(2, msgs.Count);
            Assert.Equal(ChatRole.User, msgs[0].Role);
            Assert.Equal(ChatRole.Assistant, msgs[1].Role);
            var cit = Assert.Single(msgs[1].Citations);
            Assert.Equal(1, cit.Marker);
            Assert.Equal(42, cit.ChunkId);
            Assert.Equal(7, cit.SourceId);
            Assert.Equal("snip", cit.Snippet);
            Assert.Empty(msgs[0].Citations);
        }
    }

    [Fact]
    public void EmptyCitationsStoredAsNull()
    {
        var (store, nb) = Fresh();
        using (store)
        {
            var sid = store.CreateChatSession(nb, "s").Id!.Value;
            store.AppendMessage(new ChatMessage(null, sid, ChatRole.User, "x",
                Array.Empty<Citation>(), DateTime.UtcNow));
            var raw = Dapper.SqlMapper.ExecuteScalar<object?>(store.Connection,
                "SELECT citations_json FROM messages WHERE session_id=$sid",
                new { sid });
            Assert.True(raw is null || raw is DBNull);
        }
    }

    [Fact]
    public void DeleteChatSessionCascadesMessages()
    {
        var (store, nb) = Fresh();
        using (store)
        {
            var sid = store.CreateChatSession(nb, "s").Id!.Value;
            store.AppendMessage(new ChatMessage(null, sid, ChatRole.User, "x",
                Array.Empty<Citation>(), DateTime.UtcNow));
            store.DeleteChatSession(sid);
            Assert.Empty(store.Messages(sid));
        }
    }
}
```

> NOTE: `store.Connection` is `internal`; the test project needs `[assembly: InternalsVisibleTo("AINotebook.Core.Tests")]` on the Core project (added by Writer A in the project setup task). If unavailable, replace the `EmptyCitationsStoredAsNull` raw-query assertion with reading back via `store.Messages(sid)` and asserting `Assert.Empty(msgs[0].Citations)`.

- [ ] **Step 2: Run — Expected: FAIL.**

```
dotnet test windows/tests/AINotebook.Core.Tests --filter "FullyQualifiedName~NotebookStoreChatTests"
```

Expected: FAIL.

- [ ] **Step 3: Implement the Chat partial.** Create `windows/src/AINotebook.Core/Storage/NotebookStore.Chat.cs`:

```csharp
using System.Text.Json;
using System.Text.Json.Serialization;
using AINotebook.Core.Models;
using Dapper;

namespace AINotebook.Core.Storage;

public sealed partial class NotebookStore
{
    // Swift JSONEncoder default keys are camelCase. snippet/marker are already
    // camelCase; chunkId/sourceId map to "chunkId"/"sourceId".
    private sealed record CitationJson(
        [property: JsonPropertyName("marker")] int Marker,
        [property: JsonPropertyName("chunkId")] long ChunkId,
        [property: JsonPropertyName("sourceId")] long SourceId,
        [property: JsonPropertyName("snippet")] string Snippet);

    public ChatSession CreateChatSession(long notebookId, string title)
    {
        var trimmed = title.Trim();
        var resolved = trimmed.Length == 0 ? "New chat" : trimmed;
        var now = DateTime.UtcNow;
        var id = Connection.ExecuteScalar<long>(
            """
            INSERT INTO chat_sessions(notebook_id, title, created_at)
            VALUES($nb, $title, $created);
            SELECT last_insert_rowid();
            """,
            new { nb = notebookId, title = resolved, created = SqliteDate.ToDb(now) });
        return new ChatSession(id, notebookId, resolved, now);
    }

    public IReadOnlyList<ChatSession> ChatSessions(long notebookId) =>
        Connection.Query(
            "SELECT id, notebook_id, title, created_at FROM chat_sessions WHERE notebook_id=$nb ORDER BY created_at DESC",
            new { nb = notebookId })
            .Select(r => new ChatSession((long)r.id, (long)r.notebook_id, (string)r.title,
                SqliteDate.FromDb((string)r.created_at)))
            .ToList();

    public void DeleteChatSession(long id) =>
        Connection.Execute("DELETE FROM chat_sessions WHERE id=$id", new { id });

    public void AppendMessage(ChatMessage message)
    {
        string? json = message.Citations.Count == 0
            ? null
            : JsonSerializer.Serialize(
                message.Citations.Select(c => new CitationJson(c.Marker, c.ChunkId, c.SourceId, c.Snippet)).ToList());
        Connection.Execute(
            """
            INSERT INTO messages(session_id, role, content, citations_json, created_at)
            VALUES($sid, $role, $content, $cit, $created)
            """,
            new
            {
                sid = message.SessionId, role = message.Role.ToDb(), content = message.Content,
                cit = json, created = SqliteDate.ToDb(message.CreatedAt)
            });
    }

    public IReadOnlyList<ChatMessage> Messages(long sessionId) =>
        Connection.Query(
            "SELECT id, session_id, role, content, citations_json, created_at FROM messages WHERE session_id=$sid ORDER BY created_at ASC",
            new { sid = sessionId })
            .Select(r =>
            {
                IReadOnlyList<Citation> cits = Array.Empty<Citation>();
                if (r.citations_json is string raw && raw.Length > 0)
                {
                    var decoded = JsonSerializer.Deserialize<List<CitationJson>>(raw);
                    if (decoded is not null)
                        cits = decoded.Select(c => new Citation(c.Marker, c.ChunkId, c.SourceId, c.Snippet)).ToList();
                }
                return new ChatMessage(
                    (long)r.id, (long)r.session_id, ChatRoleExtensions.FromDb((string)r.role),
                    (string)r.content, cits, SqliteDate.FromDb((string)r.created_at));
            })
            .ToList();
}
```

> NOTE: `ChatRole.ToDb()`/`ChatRoleExtensions.FromDb` map the enum to `"system"`/`"user"`/`"assistant"` (Writer A's model). `ChatMessage`/`Citation` records per SHARED TYPE CONTRACT.

- [ ] **Step 4: Run — Expected: PASS.**

```
dotnet test windows/tests/AINotebook.Core.Tests --filter "FullyQualifiedName~NotebookStoreChatTests"
```

Expected: PASS (5 tests).

- [ ] **Step 5: Commit.**

```
git add windows/src/AINotebook.Core/Storage/NotebookStore.Chat.cs windows/tests/AINotebook.Core.Tests/Storage/NotebookStoreChatTests.cs
git commit -m "feat(core): chat sessions + messages + citations_json (camelCase, NULL-when-empty)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 10 — Notes CRUD + note versions

**Files:**
- Create: `windows/src/AINotebook.Core/Storage/NotebookStore.Notes.cs`
- Create: `windows/src/AINotebook.Core/Storage/NotebookStore.NoteVersions.cs`
- Test: `windows/tests/AINotebook.Core.Tests/Storage/NotebookStoreNotesTests.cs`
- Test: `windows/tests/AINotebook.Core.Tests/Storage/NoteVersionStoreTests.cs`

`CreateNote` defaults origin `Manual`, generates a lowercased 36-char UUID, fires `OnNoteSaved`. `Notes()` ordered `updated_at DESC`. `UpdateNote` first snapshots the PRE-update content as an `Autosave` version (order matters), then trims title, sets body, bumps `updated_at`, and fires `OnNoteSaved`. `DeleteNote` returns the note's UUID, deletes (cascading attachments + versions), and fires `OnNoteDeleted`. Note versions: `SnapshotNoteVersion` inserts then prunes (cap 50, delete oldest by `saved_at ASC`); `RestoreNoteVersion` snapshots current as `Restore` then overwrites the note. Cite: `Sources/AINotebookCore/NotebookStore+Notes.swift`, `NotebookStore+NoteVersions.swift`.

- [ ] **Step 1: Write failing Notes tests.** Create `windows/tests/AINotebook.Core.Tests/Storage/NotebookStoreNotesTests.cs`:

```csharp
using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using Xunit;

namespace AINotebook.Core.Tests.Storage;

public class NotebookStoreNotesTests
{
    private static (NotebookStore store, long nb) Fresh()
    {
        var store = new NotebookStore(StorePath.InMemory);
        return (store, store.CreateNotebook("N").Id!.Value);
    }

    [Fact]
    public void CreateNoteDefaultsToManualAndGetsLowercased36CharUuid()
    {
        var (store, nb) = Fresh();
        using (store)
        {
            var note = store.CreateNote(nb, "  Title  ", "body");
            Assert.Equal(NoteOrigin.Manual, note.Origin);
            Assert.Equal("Title", note.Title);
            Assert.Equal(36, note.NoteUuid.Length);
            Assert.Contains("-", note.NoteUuid);
            Assert.Equal(note.NoteUuid.ToLowerInvariant(), note.NoteUuid);
            Assert.Null(note.AutoSourceId);
        }
    }

    [Fact]
    public void NotesOrderedByUpdatedAtDesc()
    {
        var (store, nb) = Fresh();
        using (store)
        {
            store.CreateNote(nb, "a", "x");
            var b = store.CreateNote(nb, "b", "x");
            Assert.Equal(b.Id, store.Notes(nb)[0].Id);
        }
    }

    [Fact]
    public void UpdateNoteTrimsTitleSetsBodyAndBumpsUpdatedAt()
    {
        var (store, nb) = Fresh();
        using (store)
        {
            var note = store.CreateNote(nb, "t", "v1");
            var before = note.UpdatedAt;
            store.UpdateNote(note.Id!.Value, "  t2 ", "v2");
            var reloaded = store.Note(note.Id!.Value)!;
            Assert.Equal("t2", reloaded.Title);
            Assert.Equal("v2", reloaded.BodyMd);
            Assert.True(reloaded.UpdatedAt >= before);
        }
    }

    [Fact]
    public void TransformationOriginWithOriginRefPersists()
    {
        var (store, nb) = Fresh();
        using (store)
        {
            var note = store.CreateNote(nb, "t", "b", NoteOrigin.Transformation, originRef: 999);
            var reloaded = store.Note(note.Id!.Value)!;
            Assert.Equal(NoteOrigin.Transformation, reloaded.Origin);
            Assert.Equal(999, reloaded.OriginRef);
        }
    }

    [Fact]
    public void DeleteNoteReturnsUuidAndRemoves()
    {
        var (store, nb) = Fresh();
        using (store)
        {
            var note = store.CreateNote(nb, "t", "b");
            var uuid = store.DeleteNote(note.Id!.Value);
            Assert.Equal(note.NoteUuid, uuid);
            Assert.Empty(store.Notes(nb));
        }
    }
}
```

- [ ] **Step 2: Write failing NoteVersion tests** (ported: autosave/manual/restore/cap). Create `windows/tests/AINotebook.Core.Tests/Storage/NoteVersionStoreTests.cs`:

```csharp
using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using Xunit;

namespace AINotebook.Core.Tests.Storage;

public class NoteVersionStoreTests
{
    private static (NotebookStore store, long noteId) Fresh()
    {
        var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("N").Id!.Value;
        var note = store.CreateNote(nb, "t", "v1");
        return (store, note.Id!.Value);
    }

    [Fact]
    public void UpdateNoteSnapshotsPreviousBodyAsAutosave()
    {
        var (store, noteId) = Fresh();
        using (store)
        {
            store.UpdateNote(noteId, "t", "v2");
            var versions = store.NoteVersions(noteId);
            Assert.Single(versions);
            Assert.Equal(NoteVersionReason.Autosave, versions[0].Reason);
            Assert.Equal("v1", versions[0].BodyMd);
        }
    }

    [Fact]
    public void ManualSnapshotUsesManualReason()
    {
        var (store, noteId) = Fresh();
        using (store)
        {
            store.SnapshotNoteVersion(noteId, NoteVersionReason.Manual);
            Assert.Equal(NoteVersionReason.Manual, store.NoteVersions(noteId).Single().Reason);
        }
    }

    [Fact]
    public void RestoreSnapshotsCurrentAsRestoreThenOverwritesBody()
    {
        var (store, noteId) = Fresh();
        using (store)
        {
            // first update creates an autosave version holding "v1"
            store.UpdateNote(noteId, "t", "v2");
            var v1Version = store.NoteVersions(noteId).Single(v => v.BodyMd == "v1");
            store.RestoreNoteVersion(v1Version.Id!.Value);
            Assert.Equal("v1", store.Note(noteId)!.BodyMd);
            var versions = store.NoteVersions(noteId);
            Assert.True(versions.Count >= 2);
            Assert.Contains(versions, v => v.Reason == NoteVersionReason.Restore && v.BodyMd == "v2");
        }
    }

    [Fact]
    public void VersionsCappedAtFiftyOldestPruned()
    {
        var (store, noteId) = Fresh();
        using (store)
        {
            for (int i = 0; i < 60; i++)
                store.UpdateNote(noteId, "t", $"body {i}");
            Assert.True(store.NoteVersions(noteId).Count <= 50);
        }
    }
}
```

- [ ] **Step 3: Run — Expected: FAIL.**

```
dotnet test windows/tests/AINotebook.Core.Tests --filter "FullyQualifiedName~NotebookStoreNotesTests|FullyQualifiedName~NoteVersionStoreTests"
```

Expected: FAIL.

- [ ] **Step 4: Implement the Notes partial.** Create `windows/src/AINotebook.Core/Storage/NotebookStore.Notes.cs`:

```csharp
using AINotebook.Core.Models;
using Dapper;

namespace AINotebook.Core.Storage;

public sealed partial class NotebookStore
{
    private const string NoteCols =
        "id, notebook_id, title, body_md, origin, origin_ref, auto_source_id, note_uuid, created_at, updated_at";

    private static Note MapNote(dynamic r) => new Note(
        (long)r.id, (long)r.notebook_id, (string)r.title, (string)r.body_md,
        NoteOriginExtensions.FromDb((string)r.origin),
        r.origin_ref is null ? (long?)null : (long)r.origin_ref,
        r.auto_source_id is null ? (long?)null : (long)r.auto_source_id,
        (string)r.note_uuid,
        SqliteDate.FromDb((string)r.created_at), SqliteDate.FromDb((string)r.updated_at));

    public Note CreateNote(long notebookId, string title, string bodyMd,
        NoteOrigin origin = NoteOrigin.Manual, long? originRef = null)
    {
        var now = DateTime.UtcNow;
        var uuid = Guid.NewGuid().ToString().ToLowerInvariant();
        var trimmed = title.Trim();
        var id = Connection.ExecuteScalar<long>(
            """
            INSERT INTO notes(notebook_id, title, body_md, origin, origin_ref, note_uuid, created_at, updated_at)
            VALUES($nb, $title, $body, $origin, $ref, $uuid, $created, $updated);
            SELECT last_insert_rowid();
            """,
            new
            {
                nb = notebookId, title = trimmed, body = bodyMd, origin = origin.ToDb(),
                @ref = originRef, uuid, created = SqliteDate.ToDb(now), updated = SqliteDate.ToDb(now)
            });
        FireNoteSaved(id);
        return new Note(id, notebookId, trimmed, bodyMd, origin, originRef, null, uuid, now, now);
    }

    public IReadOnlyList<Note> Notes(long notebookId) =>
        Connection.Query(
            $"SELECT {NoteCols} FROM notes WHERE notebook_id=$nb ORDER BY updated_at DESC",
            new { nb = notebookId })
            .Select(r => MapNote(r)).ToList();

    public Note? Note(long id)
    {
        var row = Connection.QueryFirstOrDefault($"SELECT {NoteCols} FROM notes WHERE id=$id", new { id });
        return row is null ? null : MapNote(row);
    }

    public void UpdateNote(long id, string title, string bodyMd)
    {
        // Snapshot the PRE-update content as an autosave version FIRST.
        SnapshotNoteVersion(id, NoteVersionReason.Autosave);
        Connection.Execute(
            "UPDATE notes SET title=$title, body_md=$body, updated_at=$updated WHERE id=$id",
            new { title = title.Trim(), body = bodyMd, updated = SqliteDate.ToDb(DateTime.UtcNow), id });
        FireNoteSaved(id);
    }

    public string? DeleteNote(long id)
    {
        var uuid = Connection.QueryFirstOrDefault<string?>(
            "SELECT note_uuid FROM notes WHERE id=$id", new { id });
        Connection.Execute("DELETE FROM notes WHERE id=$id", new { id });
        if (uuid is not null && OnNoteDeleted is not null)
            _ = OnNoteDeleted(uuid);
        return uuid;
    }

    public void LinkNoteToShadowSource(long noteId, long sourceId) =>
        Connection.Execute("UPDATE notes SET auto_source_id=$src WHERE id=$id",
            new { src = sourceId, id = noteId });

    private void FireNoteSaved(long noteId)
    {
        if (OnNoteSaved is not null) _ = OnNoteSaved(noteId);
    }
}
```

- [ ] **Step 5: Implement the NoteVersions partial.** Create `windows/src/AINotebook.Core/Storage/NotebookStore.NoteVersions.cs`:

```csharp
using AINotebook.Core.Models;
using Dapper;

namespace AINotebook.Core.Storage;

public sealed partial class NotebookStore
{
    public const int NoteVersionCap = 50;

    public IReadOnlyList<NoteVersion> NoteVersions(long noteId) =>
        Connection.Query(
            "SELECT id, note_id, title, body_md, saved_at, reason FROM note_versions WHERE note_id=$nid ORDER BY saved_at ASC",
            new { nid = noteId })
            .Select(r => new NoteVersion(
                (long)r.id, (long)r.note_id, (string)r.title, (string)r.body_md,
                SqliteDate.FromDb((string)r.saved_at),
                NoteVersionReasonExtensions.FromDb((string)r.reason)))
            .ToList();

    public NoteVersion? SnapshotNoteVersion(long noteId, NoteVersionReason reason)
    {
        var note = Note(noteId);
        if (note is null) return null;
        var savedAt = DateTime.UtcNow;
        var id = Connection.ExecuteScalar<long>(
            """
            INSERT INTO note_versions(note_id, title, body_md, saved_at, reason)
            VALUES($nid, $title, $body, $saved, $reason);
            SELECT last_insert_rowid();
            """,
            new { nid = noteId, title = note.Title, body = note.BodyMd, saved = SqliteDate.ToDb(savedAt), reason = reason.ToDb() });
        PruneIfNeeded(noteId);
        return new NoteVersion(id, noteId, note.Title, note.BodyMd, savedAt, reason);
    }

    public void RestoreNoteVersion(long versionId)
    {
        var row = Connection.QueryFirstOrDefault(
            "SELECT note_id, title, body_md FROM note_versions WHERE id=$id", new { id = versionId });
        if (row is null) return;
        long noteId = (long)row.note_id;
        var current = Note(noteId);
        if (current is not null)
        {
            Connection.Execute(
                """
                INSERT INTO note_versions(note_id, title, body_md, saved_at, reason)
                VALUES($nid, $title, $body, $saved, $reason)
                """,
                new
                {
                    nid = noteId, title = current.Title, body = current.BodyMd,
                    saved = SqliteDate.ToDb(DateTime.UtcNow), reason = NoteVersionReason.Restore.ToDb()
                });
            PruneIfNeeded(noteId);
        }
        Connection.Execute(
            "UPDATE notes SET title=$title, body_md=$body, updated_at=$updated WHERE id=$id",
            new { title = (string)row.title, body = (string)row.body_md, updated = SqliteDate.ToDb(DateTime.UtcNow), id = noteId });
        FireNoteSaved(noteId);
    }

    private void PruneIfNeeded(long noteId)
    {
        var total = Connection.ExecuteScalar<int>(
            "SELECT count(*) FROM note_versions WHERE note_id=$nid", new { nid = noteId });
        if (total > NoteVersionCap)
        {
            Connection.Execute(
                """
                DELETE FROM note_versions
                WHERE id IN (
                  SELECT id FROM note_versions
                  WHERE note_id=$nid
                  ORDER BY saved_at ASC
                  LIMIT $limit
                )
                """,
                new { nid = noteId, limit = total - NoteVersionCap });
        }
    }
}
```

> NOTE: `NoteOrigin.ToDb()`/`NoteOriginExtensions.FromDb` (`"manual"`/`"chat"`/`"transformation"`) and `NoteVersionReason.ToDb()`/`NoteVersionReasonExtensions.FromDb` (`"autosave"`/`"manual"`/`"restore"`) come from Writer A's models. The `RestoreNoteVersion` and `UpdateNote` auto-snapshot ordering is faithful to `NotebookStore+Notes.swift:48-61` and `NotebookStore+NoteVersions.swift:34-58`.

- [ ] **Step 6: Run — Expected: PASS.**

```
dotnet test windows/tests/AINotebook.Core.Tests --filter "FullyQualifiedName~NotebookStoreNotesTests|FullyQualifiedName~NoteVersionStoreTests"
```

Expected: PASS (9 tests).

- [ ] **Step 7: Commit.**

```
git add windows/src/AINotebook.Core/Storage/NotebookStore.Notes.cs windows/src/AINotebook.Core/Storage/NotebookStore.NoteVersions.cs windows/tests/AINotebook.Core.Tests/Storage/NotebookStoreNotesTests.cs windows/tests/AINotebook.Core.Tests/Storage/NoteVersionStoreTests.cs
git commit -m "feat(core): notes CRUD + note versions (autosave/restore, cap 50) + save/delete hooks

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 11 — Transformations CRUD + runs + BuiltinTransformations seeding

**Files:**
- Create: `windows/src/AINotebook.Core/Storage/NotebookStore.Transformations.cs`
- Create: `windows/src/AINotebook.Core/Storage/BuiltinTransformations.cs`
- Test: `windows/tests/AINotebook.Core.Tests/Storage/NotebookStoreTransformationsTests.cs`
- Test: `windows/tests/AINotebook.Core.Tests/Storage/BuiltinTransformationsTests.cs`

`Transformations()` ordered `is_builtin DESC, name ASC`. CRUD + `RecordTransformationRun` + `TransformationRuns()` ordered `ran_at DESC`. `BuiltinTransformations.SeedIfNeeded` runs on every store init: idempotent by `name + is_builtin=1`, inserts missing builtins (scope `source`, `is_builtin=1`), and backfills empty/NULL descriptions for existing builtins. The exact EN/CS specs are inlined verbatim below from `BuiltinTransformations.swift` (all prompts contain `{{source_text}}`). This task **replaces** the temporary stub from Task 6. Cite: `Sources/AINotebookCore/BuiltinTransformations.swift`, `NotebookStore+Transformations.swift`.

- [ ] **Step 1: Write failing Transformations CRUD tests.** Create `windows/tests/AINotebook.Core.Tests/Storage/NotebookStoreTransformationsTests.cs`:

```csharp
using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using Xunit;

namespace AINotebook.Core.Tests.Storage;

public class NotebookStoreTransformationsTests
{
    [Fact]
    public void CreateListUpdateDelete()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        var t = store.CreateTransformation("Custom", "do {{source_text}}", TransformationScope.Source, isBuiltin: false);
        Assert.Contains(store.Transformations(), x => x.Id == t.Id && !x.IsBuiltin);

        store.UpdateTransformation(t.Id!.Value, "Custom2", "redo {{source_text}}", "desc");
        var updated = store.Transformations().Single(x => x.Id == t.Id);
        Assert.Equal("Custom2", updated.Name);
        Assert.Equal("redo {{source_text}}", updated.PromptTemplate);

        store.DeleteTransformation(t.Id!.Value);
        Assert.DoesNotContain(store.Transformations(), x => x.Id == t.Id);
    }

    [Fact]
    public void OrderedBuiltinsFirstThenNameAsc()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        store.CreateTransformation("aaa-custom", "{{source_text}}", TransformationScope.Source, isBuiltin: false);
        var list = store.Transformations();
        // all builtins precede all non-builtins
        int firstNonBuiltin = list.ToList().FindIndex(x => !x.IsBuiltin);
        Assert.True(list.Take(firstNonBuiltin).All(x => x.IsBuiltin));
    }

    [Fact]
    public void RecordRunAndList()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        var t = store.Transformations().First(x => x.IsBuiltin);
        var nb = store.CreateNotebook("N").Id!.Value;
        var note = store.CreateNote(nb, "out", "body");
        var run = store.RecordTransformationRun(t.Id!.Value, sourceId: null, resultNoteId: note.Id);
        Assert.Equal(note.Id, run.ResultNoteId);
        Assert.Contains(store.TransformationRuns(), r => r.Id == run.Id);
    }
}
```

- [ ] **Step 2: Write failing BuiltinTransformations tests (EN + CS).** Create `windows/tests/AINotebook.Core.Tests/Storage/BuiltinTransformationsTests.cs`:

```csharp
using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using Xunit;

namespace AINotebook.Core.Tests.Storage;

public class BuiltinTransformationsTests
{
    [Fact]
    public void EnglishSeedsFourBuiltinsWithExpectedNamesAndDescriptions()
    {
        using var store = new NotebookStore(StorePath.InMemory, AppLanguage.English);
        var builtins = store.Transformations().Where(t => t.IsBuiltin).ToList();
        Assert.Equal(4, builtins.Count);
        Assert.All(builtins, b =>
        {
            Assert.Equal(TransformationScope.Source, b.Scope);
            Assert.Contains("{{source_text}}", b.PromptTemplate);
        });
        var byName = builtins.ToDictionary(b => b.Name);
        Assert.Equal("3–5 bullet summary of a source.", byName["Summary"].Description);
        Assert.Equal("5–10 most important takeaways.", byName["Key points"].Description);
        Assert.Equal("People, organizations, places, dates.", byName["Entities"].Description);
        Assert.Equal("Concrete next-step actions found in the text.", byName["Action items"].Description);
    }

    [Fact]
    public void CzechSeedsFourBuiltinsWithCzechNames()
    {
        using var store = new NotebookStore(StorePath.InMemory, AppLanguage.Czech);
        var names = store.Transformations().Where(t => t.IsBuiltin).Select(t => t.Name).OrderBy(n => n).ToArray();
        Assert.Equal(new[] { "Entity", "Klíčové body", "Souhrn", "Úkoly" }, names);
    }

    [Fact]
    public void SeedIsIdempotentAcrossReopen()
    {
        var dir = Path.Combine(Path.GetTempPath(), "ainb-bt-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        var path = new StorePath(Path.Combine(dir, "db.sqlite"));
        try
        {
            using (var s1 = new NotebookStore(path, AppLanguage.English))
                Assert.Equal(4, s1.Transformations().Count(t => t.IsBuiltin));
            using (var s2 = new NotebookStore(path, AppLanguage.English))
                Assert.Equal(4, s2.Transformations().Count(t => t.IsBuiltin)); // no duplicates
        }
        finally { Directory.Delete(dir, recursive: true); }
    }

    [Fact]
    public void BackfillsEmptyDescriptionsForExistingBuiltins()
    {
        var dir = Path.Combine(Path.GetTempPath(), "ainb-bf-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        var path = new StorePath(Path.Combine(dir, "db.sqlite"));
        try
        {
            using (var s1 = new NotebookStore(path, AppLanguage.English))
            {
                // simulate a pre-v9 builtin with empty description
                Dapper.SqlMapper.Execute(s1.Connection,
                    "UPDATE transformations SET description='' WHERE name='Summary' AND is_builtin=1");
                Assert.Equal("", s1.Transformations().Single(t => t.Name == "Summary").Description);
            }
            using (var s2 = new NotebookStore(path, AppLanguage.English))
                Assert.Equal("3–5 bullet summary of a source.",
                    s2.Transformations().Single(t => t.Name == "Summary").Description);
        }
        finally { Directory.Delete(dir, recursive: true); }
    }
}
```

- [ ] **Step 3: Run — Expected: FAIL.**

```
dotnet test windows/tests/AINotebook.Core.Tests --filter "FullyQualifiedName~NotebookStoreTransformationsTests|FullyQualifiedName~BuiltinTransformationsTests"
```

Expected: FAIL.

- [ ] **Step 4: Implement the Transformations partial.** Create `windows/src/AINotebook.Core/Storage/NotebookStore.Transformations.cs`:

```csharp
using AINotebook.Core.Models;
using Dapper;

namespace AINotebook.Core.Storage;

public sealed partial class NotebookStore
{
    private const string TransformationCols =
        "id, name, prompt_template, scope, is_builtin, description";

    private static Transformation MapTransformation(dynamic r) => new Transformation(
        (long)r.id, (string)r.name, (string)r.prompt_template,
        TransformationScopeExtensions.FromDb((string)r.scope),
        ((long)r.is_builtin) != 0, (string)r.description);

    public Transformation CreateTransformation(string name, string promptTemplate,
        TransformationScope scope, bool isBuiltin = false, string description = "")
    {
        var id = Connection.ExecuteScalar<long>(
            """
            INSERT INTO transformations(name, prompt_template, scope, is_builtin, description)
            VALUES($name, $prompt, $scope, $builtin, $desc);
            SELECT last_insert_rowid();
            """,
            new { name, prompt = promptTemplate, scope = scope.ToDb(), builtin = isBuiltin ? 1 : 0, desc = description });
        return new Transformation(id, name, promptTemplate, scope, isBuiltin, description);
    }

    public IReadOnlyList<Transformation> Transformations() =>
        Connection.Query(
            $"SELECT {TransformationCols} FROM transformations ORDER BY is_builtin DESC, name ASC")
            .Select(r => MapTransformation(r)).ToList();

    public void UpdateTransformation(long id, string name, string promptTemplate, string description = "") =>
        Connection.Execute(
            "UPDATE transformations SET name=$name, prompt_template=$prompt, description=$desc WHERE id=$id",
            new { name, prompt = promptTemplate, desc = description, id });

    public void UpdateTransformationScope(long id, TransformationScope scope) =>
        Connection.Execute("UPDATE transformations SET scope=$scope WHERE id=$id",
            new { scope = scope.ToDb(), id });

    public void DeleteTransformation(long id) =>
        Connection.Execute("DELETE FROM transformations WHERE id=$id", new { id });

    public TransformationRun RecordTransformationRun(long transformationId, long? sourceId, long? resultNoteId)
    {
        var ranAt = DateTime.UtcNow;
        var id = Connection.ExecuteScalar<long>(
            """
            INSERT INTO transformation_runs(transformation_id, source_id, result_note_id, ran_at)
            VALUES($tid, $sid, $nid, $ran);
            SELECT last_insert_rowid();
            """,
            new { tid = transformationId, sid = sourceId, nid = resultNoteId, ran = SqliteDate.ToDb(ranAt) });
        return new TransformationRun(id, transformationId, sourceId, resultNoteId, ranAt);
    }

    public IReadOnlyList<TransformationRun> TransformationRuns() =>
        Connection.Query(
            "SELECT id, transformation_id, source_id, result_note_id, ran_at FROM transformation_runs ORDER BY ran_at DESC")
            .Select(r => new TransformationRun(
                (long)r.id, (long)r.transformation_id,
                r.source_id is null ? (long?)null : (long)r.source_id,
                r.result_note_id is null ? (long?)null : (long)r.result_note_id,
                SqliteDate.FromDb((string)r.ran_at)))
            .ToList();
}
```

- [ ] **Step 5: Implement BuiltinTransformations (replaces the Task 6 stub) with verbatim EN/CS prompts.** Create `windows/src/AINotebook.Core/Storage/BuiltinTransformations.cs` (and delete the temporary stub from `NotebookStore.cs`):

```csharp
using AINotebook.Core.Models;
using Dapper;
using Microsoft.Data.Sqlite;

namespace AINotebook.Core.Storage;

/// <summary>
/// Builtin transformations seeded on every store init. Idempotent by
/// (name, is_builtin=1); backfills empty/NULL descriptions. Prompts are
/// verbatim from Sources/AINotebookCore/BuiltinTransformations.swift.
/// </summary>
internal static class BuiltinTransformations
{
    private readonly record struct Spec(string Name, string Description, string Prompt);

    private static readonly Spec[] English =
    {
        new("Summary", "3–5 bullet summary of a source.",
            "Summarize the following source text in 3-5 short bullet points. Keep\n" +
            "names, numbers, and dates exact. Output Markdown bullets only — no\n" +
            "preamble.\n\n" +
            "SOURCE TEXT:\n{{source_text}}"),
        new("Key points", "5–10 most important takeaways.",
            "Extract the 5-10 most important key points from the following source\n" +
            "text. Output as a Markdown numbered list. Each item should be one\n" +
            "sentence, concrete, and self-contained.\n\n" +
            "SOURCE TEXT:\n{{source_text}}"),
        new("Entities", "People, organizations, places, dates.",
            "Extract people, organizations, places, and dates from the following\n" +
            "source text. Output as Markdown sections (## People, ## Organizations,\n" +
            "## Places, ## Dates) with bullet points under each. Include only\n" +
            "entities literally present in the text.\n\n" +
            "SOURCE TEXT:\n{{source_text}}"),
        new("Action items", "Concrete next-step actions found in the text.",
            "List every action item or next-step task mentioned in the following\n" +
            "source text. Output as a Markdown checklist (- [ ]). One item per\n" +
            "line. Include only actions literally present in the text.\n\n" +
            "SOURCE TEXT:\n{{source_text}}"),
    };

    private static readonly Spec[] Czech =
    {
        new("Souhrn", "Shrnutí zdroje do 3–5 odrážek.",
            "Shrň následující zdrojový text do 3–5 krátkých odrážek. Zachovej přesně\n" +
            "jména, čísla a data. Výstup pouze jako odrážky v Markdownu — bez úvodu.\n\n" +
            "ZDROJOVÝ TEXT:\n{{source_text}}"),
        new("Klíčové body", "5–10 nejdůležitějších bodů.",
            "Extrahuj 5–10 nejdůležitějších klíčových bodů z následujícího zdrojového\n" +
            "textu. Výstup jako Markdown číslovaný seznam. Každý bod jednou větou,\n" +
            "konkrétně a sám o sobě srozumitelný.\n\n" +
            "ZDROJOVÝ TEXT:\n{{source_text}}"),
        new("Entity", "Lidé, organizace, místa, data.",
            "Extrahuj osoby, organizace, místa a data z následujícího zdrojového textu.\n" +
            "Výstup jako Markdown sekce (## Osoby, ## Organizace, ## Místa, ## Data)\n" +
            "s odrážkami pod každou. Zahrň pouze entity doslova přítomné v textu.\n\n" +
            "ZDROJOVÝ TEXT:\n{{source_text}}"),
        new("Úkoly", "Konkrétní úkoly nebo akce zmíněné v textu.",
            "Vypiš všechny úkoly nebo další kroky uvedené v následujícím zdrojovém\n" +
            "textu. Výstup jako Markdown checklist (- [ ]). Jeden úkol na řádek.\n" +
            "Zahrň pouze úkoly doslova přítomné v textu.\n\n" +
            "ZDROJOVÝ TEXT:\n{{source_text}}"),
    };

    internal static void SeedIfNeeded(SqliteConnection conn, AppLanguage language)
    {
        var specs = language == AppLanguage.Czech ? Czech : English;
        foreach (var s in specs)
        {
            var exists = conn.ExecuteScalar<long?>(
                "SELECT 1 FROM transformations WHERE name=$name AND is_builtin=1",
                new { name = s.Name }) is not null;
            if (!exists)
            {
                conn.Execute(
                    """
                    INSERT INTO transformations(name, prompt_template, scope, is_builtin, description)
                    VALUES($name, $prompt, 'source', 1, $desc)
                    """,
                    new { name = s.Name, prompt = s.Prompt, desc = s.Description });
            }
            else
            {
                conn.Execute(
                    """
                    UPDATE transformations
                       SET description = $desc
                     WHERE name = $name AND is_builtin = 1 AND (description IS NULL OR description = '')
                    """,
                    new { desc = s.Description, name = s.Name });
            }
        }
    }
}
```

> NOTE: The Swift prompts use a soft line-wrap inside one logical paragraph; reproduced verbatim including the en-dash `—` and `{{source_text}}` placeholder. `TransformationScope.ToDb()`/`TransformationScopeExtensions.FromDb` (`"source"`/`"notebook"`) come from Writer A's model. Remove the temporary `BuiltinTransformations` stub added in Task 6 so this real implementation is the only one.

- [ ] **Step 6: Run — Expected: PASS.**

```
dotnet test windows/tests/AINotebook.Core.Tests --filter "FullyQualifiedName~NotebookStoreTransformationsTests|FullyQualifiedName~BuiltinTransformationsTests"
```

Expected: PASS (7 tests).

- [ ] **Step 7: Commit.**

```
git add windows/src/AINotebook.Core/Storage/NotebookStore.Transformations.cs windows/src/AINotebook.Core/Storage/BuiltinTransformations.cs windows/src/AINotebook.Core/Storage/NotebookStore.cs windows/tests/AINotebook.Core.Tests/Storage/NotebookStoreTransformationsTests.cs windows/tests/AINotebook.Core.Tests/Storage/BuiltinTransformationsTests.cs
git commit -m "feat(core): transformations CRUD + runs + builtin EN/CS seeding (verbatim prompts)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 12 — AttachmentStore (disk + DB)

**Files:**
- Create: `windows/src/AINotebook.Core/Storage/AttachmentStore.cs`
- Test: `windows/tests/AINotebook.Core.Tests/Storage/AttachmentStoreTests.cs`

`AttachmentStore(NotebookStore store, string root)` creates `root` on construction. `Save(noteId, noteUuid, filename, mime, bytes)` writes `<root>/<noteUuid>/<filename>`, resolving collisions by appending `" (n)"` to the stem before the extension starting at `n=2` (e.g. `x.png` → `x (2).png`), inserts an `attachments` row with the resolved filename + `byteSize`, and returns a `NoteAttachment`. `Read(noteUuid, filename)` returns exact bytes. `List(noteId)` ordered `created_at ASC`. `DeleteFolder(noteUuid)` removes the folder. Cite: `Sources/AINotebookCore/AttachmentStore.swift`.

- [ ] **Step 1: Write failing tests** (ported: save/collision/read/deleteFolder). Create `windows/tests/AINotebook.Core.Tests/Storage/AttachmentStoreTests.cs`:

```csharp
using System.Text;
using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using Xunit;

namespace AINotebook.Core.Tests.Storage;

public class AttachmentStoreTests : IDisposable
{
    private readonly NotebookStore _store;
    private readonly string _root;
    private readonly long _noteId;
    private readonly string _noteUuid;

    public AttachmentStoreTests()
    {
        _store = new NotebookStore(StorePath.InMemory);
        var nb = _store.CreateNotebook("N").Id!.Value;
        var note = _store.CreateNote(nb, "t", "b");
        _noteId = note.Id!.Value;
        _noteUuid = note.NoteUuid;
        _root = Path.Combine(Path.GetTempPath(), "ainb-att-" + Guid.NewGuid().ToString("N"));
    }

    public void Dispose()
    {
        _store.Dispose();
        if (Directory.Exists(_root)) Directory.Delete(_root, recursive: true);
    }

    [Fact]
    public void SaveWritesFileAndDbRowAndListReturnsOne()
    {
        var att = new AttachmentStore(_store, _root);
        var bytes = Encoding.UTF8.GetBytes("hello");
        var saved = att.Save(_noteId, _noteUuid, "x.png", "image/png", bytes);
        Assert.NotNull(saved.Id);
        Assert.Equal("x.png", saved.Filename);
        Assert.Equal(bytes.Length, saved.ByteSize);
        Assert.True(File.Exists(Path.Combine(_root, _noteUuid, "x.png")));
        Assert.Single(att.List(_noteId));
    }

    [Fact]
    public void CollisionRenamesWithParenTwo()
    {
        var att = new AttachmentStore(_store, _root);
        att.Save(_noteId, _noteUuid, "x.png", "image/png", new byte[] { 1 });
        var second = att.Save(_noteId, _noteUuid, "x.png", "image/png", new byte[] { 2 });
        Assert.Contains("(2)", second.Filename);
        Assert.Equal("x (2).png", second.Filename);
        Assert.True(File.Exists(Path.Combine(_root, _noteUuid, "x (2).png")));
    }

    [Fact]
    public void ReadReturnsExactBytes()
    {
        var att = new AttachmentStore(_store, _root);
        var bytes = new byte[] { 9, 8, 7, 6 };
        att.Save(_noteId, _noteUuid, "blob.bin", "application/octet-stream", bytes);
        Assert.Equal(bytes, att.Read(_noteUuid, "blob.bin"));
    }

    [Fact]
    public void DeleteFolderRemovesTheNoteUuidFolder()
    {
        var att = new AttachmentStore(_store, _root);
        att.Save(_noteId, _noteUuid, "x.png", "image/png", new byte[] { 1 });
        att.DeleteFolder(_noteUuid);
        Assert.False(Directory.Exists(Path.Combine(_root, _noteUuid)));
    }
}
```

- [ ] **Step 2: Run — Expected: FAIL.**

```
dotnet test windows/tests/AINotebook.Core.Tests --filter "FullyQualifiedName~AttachmentStoreTests"
```

Expected: FAIL.

- [ ] **Step 3: Implement AttachmentStore.** Create `windows/src/AINotebook.Core/Storage/AttachmentStore.cs`:

```csharp
using AINotebook.Core.Models;
using Dapper;

namespace AINotebook.Core.Storage;

/// <summary>
/// Stores attachment bytes on disk under root/&lt;noteUuid&gt;/&lt;filename&gt;
/// and a row in the attachments table. Faithful to AttachmentStore.swift.
/// </summary>
public sealed class AttachmentStore
{
    private readonly NotebookStore _store;
    public string Root { get; }

    public AttachmentStore(NotebookStore store, string root)
    {
        _store = store;
        Root = root;
        Directory.CreateDirectory(root);
    }

    /// <summary>%APPDATA%\AINotebook\attachments, created on demand.</summary>
    public static string DefaultRoot()
    {
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        var dir = Path.Combine(appData, "AINotebook", "attachments");
        Directory.CreateDirectory(dir);
        return dir;
    }

    public NoteAttachment Save(long noteId, string noteUuid, string filename, string mime, byte[] bytes)
    {
        var folder = Path.Combine(Root, noteUuid);
        Directory.CreateDirectory(folder);
        var resolved = UniqueFilename(folder, filename);
        File.WriteAllBytes(Path.Combine(folder, resolved), bytes);

        var now = DateTime.UtcNow;
        var id = _store.Connection.ExecuteScalar<long>(
            """
            INSERT INTO attachments(note_id, note_uuid, filename, mime, byte_size, created_at)
            VALUES($nid, $uuid, $file, $mime, $size, $created);
            SELECT last_insert_rowid();
            """,
            new { nid = noteId, uuid = noteUuid, file = resolved, mime, size = (long)bytes.Length, created = SqliteDate.ToDb(now) });
        return new NoteAttachment(id, noteId, noteUuid, resolved, mime, bytes.Length, now);
    }

    public byte[] Read(string noteUuid, string filename) =>
        File.ReadAllBytes(Path.Combine(Root, noteUuid, filename));

    public IReadOnlyList<NoteAttachment> List(long noteId) =>
        _store.Connection.Query(
            "SELECT id, note_id, note_uuid, filename, mime, byte_size, created_at FROM attachments WHERE note_id=$nid ORDER BY created_at ASC",
            new { nid = noteId })
            .Select(r => new NoteAttachment(
                (long)r.id, (long)r.note_id, (string)r.note_uuid, (string)r.filename,
                (string)r.mime, (long)r.byte_size, SqliteDate.FromDb((string)r.created_at)))
            .ToList();

    public void DeleteFolder(string noteUuid)
    {
        var folder = Path.Combine(Root, noteUuid);
        if (Directory.Exists(folder)) Directory.Delete(folder, recursive: true);
    }

    private static string UniqueFilename(string folder, string requested)
    {
        var stem = Path.GetFileNameWithoutExtension(requested);
        var ext = Path.GetExtension(requested); // includes leading '.' or "" if none
        var candidate = requested;
        var n = 2;
        while (File.Exists(Path.Combine(folder, candidate)))
        {
            candidate = $"{stem} ({n}){ext}";
            n++;
            if (n > 9999) break;
        }
        return candidate;
    }
}
```

> NOTE: `NoteAttachment(long? Id, long NoteId, string NoteUuid, string Filename, string Mime, long ByteSize, DateTime CreatedAt)` per SHARED TYPE CONTRACT. `_store.Connection` is `internal` — the test/library access relies on `InternalsVisibleTo` (Writer A's project setup) and same-assembly access from `AttachmentStore`. `Path.GetExtension` returns the leading dot (matching Swift's `".\(ext)"`), so `x.png` → `x (2).png` and an extensionless `data` → `data (2)`.

- [ ] **Step 4: Run — Expected: PASS.**

```
dotnet test windows/tests/AINotebook.Core.Tests --filter "FullyQualifiedName~AttachmentStoreTests"
```

Expected: PASS (4 tests).

- [ ] **Step 5: Commit.**

```
git add windows/src/AINotebook.Core/Storage/AttachmentStore.cs windows/tests/AINotebook.Core.Tests/Storage/AttachmentStoreTests.cs
git commit -m "feat(core): AttachmentStore disk+DB (collision rename, read, list, deleteFolder)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 13: Cosine similarity

Faithful 1:1 port of `Cosine.similarity` (Swift uses Accelerate `vDSP_dotpr` / `vDSP_svesq`; the C# version computes the same dot product and squared magnitudes in a single pass). Returns `0` when lengths differ, either input is empty, or the denominator is `0`. Range `[-1, 1]`.

**Files:**
- Create: `windows/src/AINotebook.Core/Rag/Cosine.cs`
- Test: `windows/tests/AINotebook.Core.Tests/Rag/CosineTests.cs`

- [ ] **Step 1: Write the failing test.** Create `windows/tests/AINotebook.Core.Tests/Rag/CosineTests.cs` with the verbatim assertions ported from `CosineTests.swift` (`identical=1`, `orthogonal=0`, `opposite=-1`, zero-magnitude=0, mismatched dim=0; accuracy `1e-5`):

```csharp
using AINotebook.Core.Rag;
using Xunit;

namespace AINotebook.Core.Tests.Rag;

public class CosineTests
{
    private const float Tol = 1e-5f;

    [Fact]
    public void IdenticalVectorsScoreOne()
    {
        float[] a = { 0.1f, 0.2f, 0.3f, 0.4f };
        Assert.Equal(1.0f, Cosine.Similarity(a, a), Tol);
    }

    [Fact]
    public void OrthogonalVectorsScoreZero()
    {
        float[] a = { 1, 0, 0, 0 };
        float[] b = { 0, 1, 0, 0 };
        Assert.Equal(0.0f, Cosine.Similarity(a, b), Tol);
    }

    [Fact]
    public void OppositeVectorsScoreMinusOne()
    {
        float[] a = { 1, 2, 3 };
        float[] b = { -1, -2, -3 };
        Assert.Equal(-1.0f, Cosine.Similarity(a, b), Tol);
    }

    [Fact]
    public void ZeroMagnitudeReturnsZero()
    {
        float[] a = { 0, 0, 0 };
        float[] b = { 1, 2, 3 };
        Assert.Equal(0.0f, Cosine.Similarity(a, b), Tol);
    }

    [Fact]
    public void MismatchedDimensionsReturnsZero()
    {
        float[] a = { 1, 2, 3 };
        float[] b = { 1, 2 };
        Assert.Equal(0.0f, Cosine.Similarity(a, b), Tol);
    }
}
```

- [ ] **Step 2: Run the test (Expected: FAIL — type `Cosine` does not exist).**

```
dotnet test windows/tests/AINotebook.Core.Tests --filter "FullyQualifiedName~CosineTests"
```
Expected: FAIL (compile error: `Cosine` not found).

- [ ] **Step 3: Implement `Cosine`.** Create `windows/src/AINotebook.Core/Rag/Cosine.cs`. Single-pass dot + squared magnitudes; `denom = sqrt(magA) * sqrt(magB)`; guard `denom > 0` else `0`:

```csharp
namespace AINotebook.Core.Rag;

/// <summary>
/// Cosine similarity in [-1, 1]. Returns 0 when either input is zero-magnitude
/// or the dimensions don't match. 1:1 port of Sources/AINotebookCore/Cosine.swift.
/// </summary>
public static class Cosine
{
    public static float Similarity(float[] a, float[] b)
    {
        if (a.Length != b.Length || a.Length == 0)
        {
            return 0f;
        }

        float dot = 0f;
        float magA = 0f;
        float magB = 0f;
        for (int i = 0; i < a.Length; i++)
        {
            dot += a[i] * b[i];
            magA += a[i] * a[i];
            magB += b[i] * b[i];
        }

        float denom = MathF.Sqrt(magA) * MathF.Sqrt(magB);
        if (denom <= 0f)
        {
            return 0f;
        }

        return dot / denom;
    }
}
```

- [ ] **Step 4: Run the test (Expected: PASS).**

```
dotnet test windows/tests/AINotebook.Core.Tests --filter "FullyQualifiedName~CosineTests"
```
Expected: PASS (5 tests).

- [ ] **Step 5: Commit.**

```
git add windows/src/AINotebook.Core/Rag/Cosine.cs windows/tests/AINotebook.Core.Tests/Rag/CosineTests.cs
git commit -m "feat(core): port Cosine.Similarity (vDSP -> single-pass) with verbatim tests

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 14: Chunker (sliding-char-window splitter)

1:1 port of `Chunker.swift`. **CRITICAL:** Swift counts by `Character` (extended grapheme cluster), so the C# port enumerates **text elements** via `System.Globalization.StringInfo`, never `string.Length` (which counts UTF-16 code units and would diverge on emoji/combining marks). `windowChars=2048`, `overlapChars=256`, back-scan bound is the literal `200`, `EstimateTokens = Math.Max(1, (count + 3) / 4)` where `count` is the text-element count.

**Files:**
- Create: `windows/src/AINotebook.Core/Ingestion/TextElements.cs`
- Create: `windows/src/AINotebook.Core/Ingestion/Chunker.cs`
- Test: `windows/tests/AINotebook.Core.Tests/Ingestion/ChunkerTests.cs`
- (`ChunkDraft` is defined in Task 2's `SourceChunk.cs` — used here, not recreated.)

- [ ] **Step 1: `ChunkDraft` already exists (defined in Task 2).** The `public sealed record ChunkDraft(string Text, int TokenCount, int? PageHint = null);` lives in `windows/src/AINotebook.Core/Models/SourceChunk.cs` (Task 2). Chunker just constructs it (2-arg construction relies on the `PageHint = null` default). Do NOT redefine it here — `Chunker.cs` references it via `using AINotebook.Core.Models;`.

- [ ] **Step 2: Write the failing test.** Create `windows/tests/AINotebook.Core.Tests/Ingestion/ChunkerTests.cs` with verbatim assertions ported from `ChunkerTests.swift`:

```csharp
using AINotebook.Core.Ingestion;
using Xunit;

namespace AINotebook.Core.Tests.Ingestion;

public class ChunkerTests
{
    [Fact]
    public void ShortTextProducesSingleChunk()
    {
        var drafts = Chunker.Chunk("Hello world.");
        Assert.Single(drafts);
        Assert.Equal("Hello world.", drafts[0].Text);
        Assert.True(drafts[0].TokenCount > 0);
    }

    [Fact]
    public void EmptyOrWhitespaceProducesNoChunks()
    {
        Assert.Empty(Chunker.Chunk(""));
        Assert.Empty(Chunker.Chunk("   \n\t "));
    }

    [Fact]
    public void LongTextSplitsIntoMultipleChunks()
    {
        var para = string.Concat(Enumerable.Repeat("word ", 2000)); // ~10 000 chars
        var drafts = Chunker.Chunk(para);
        Assert.True(drafts.Count > 1);
        // Every chunk under the hard cap (2 048 chars + small slack for not breaking mid-word).
        foreach (var d in drafts)
        {
            Assert.True(TextElements.Count(d.Text) <= 2_100, $"chunk too big: {TextElements.Count(d.Text)}");
        }
    }

    [Fact]
    public void ChunksOverlap()
    {
        var para = string.Concat(Enumerable.Repeat("word ", 2000));
        var drafts = Chunker.Chunk(para);
        Assert.True(drafts.Count >= 2, "need at least 2 chunks");
        // Last 200 chars of chunk N appear at the start of chunk N+1 (256-char overlap window).
        var tail = new string(drafts[0].Text.AsSpan(drafts[0].Text.Length - 200).ToArray());
        Assert.Contains(tail[..100], drafts[1].Text);
    }

    [Fact]
    public void WindowAndOverlapAreOverridable()
    {
        var drafts = Chunker.Chunk(
            string.Concat(Enumerable.Repeat("a ", 500)),
            windowChars: 200,
            overlapChars: 50);
        Assert.True(drafts.Count > 3);
        foreach (var d in drafts)
        {
            Assert.True(TextElements.Count(d.Text) <= 220);
        }
    }
}
```

- [ ] **Step 3: Run the test (Expected: FAIL — `Chunker`/`TextElements` do not exist).**

```
dotnet test windows/tests/AINotebook.Core.Tests --filter "FullyQualifiedName~ChunkerTests"
```
Expected: FAIL (compile error).

- [ ] **Step 4: Implement `TextElements`** (grapheme-cluster helper to mirror Swift `Character` semantics). Create `windows/src/AINotebook.Core/Ingestion/TextElements.cs`:

```csharp
using System.Globalization;

namespace AINotebook.Core.Ingestion;

/// <summary>
/// Splits a string into Swift-`Character`-equivalent units (extended grapheme
/// clusters) using <see cref="StringInfo"/>, so chunk window/overlap offsets
/// match the macOS implementation for non-ASCII / emoji / combining marks.
/// Do NOT use string.Length (UTF-16 code units) for chunk math.
/// </summary>
public static class TextElements
{
    /// <summary>Enumerate the grapheme clusters of <paramref name="s"/> as substrings.</summary>
    public static List<string> Split(string s)
    {
        var result = new List<string>();
        var e = StringInfo.GetTextElementEnumerator(s);
        while (e.MoveNext())
        {
            result.Add((string)e.Current);
        }
        return result;
    }

    /// <summary>Count of grapheme clusters (Swift `String.count`).</summary>
    public static int Count(string s)
    {
        int n = 0;
        var e = StringInfo.GetTextElementEnumerator(s);
        while (e.MoveNext())
        {
            n++;
        }
        return n;
    }
}
```

- [ ] **Step 5: Implement `Chunker`.** Create `windows/src/AINotebook.Core/Ingestion/Chunker.cs`. Port the exact step logic from `Chunker.swift` lines 10-68: trim (whitespace + newlines), early `[]` for empty, single-chunk fast path when element-count `<= windowChars`, then the sliding window over the grapheme-cluster array with whitespace back-scan bounded to `200`, re-trim each slice, overlap step `max(end - overlapChars, start + 1)`:

```csharp
using AINotebook.Core.Models;

namespace AINotebook.Core.Ingestion;

/// <summary>
/// Pure, deterministic text splitter. Produces overlapping windows of
/// approximately windowChars grapheme clusters. Always breaks on whitespace
/// boundaries so words are never split. 1:1 port of Sources/AINotebookCore/Chunker.swift.
/// Counting is by extended grapheme cluster (Swift Character), NOT UTF-16 code units.
/// </summary>
public static class Chunker
{
    private const int BackScanBound = 200; // literal bound from the Swift source

    public static List<ChunkDraft> Chunk(string raw, int windowChars = 2048, int overlapChars = 256)
    {
        if (windowChars <= overlapChars)
        {
            throw new ArgumentException("overlap must be smaller than window", nameof(overlapChars));
        }

        string cleaned = raw.Trim();
        if (cleaned.Length == 0)
        {
            return new List<ChunkDraft>();
        }

        var chars = TextElements.Split(cleaned);
        if (chars.Count <= windowChars)
        {
            return new List<ChunkDraft> { new ChunkDraft(cleaned, EstimateTokens(cleaned)) };
        }

        var drafts = new List<ChunkDraft>();
        int start = 0;
        while (start < chars.Count)
        {
            int end = Math.Min(start + windowChars, chars.Count);
            // Avoid splitting mid-word: scan backwards to the previous whitespace,
            // but only up to 200 chars to bound the search.
            if (end < chars.Count)
            {
                int probe = end;
                int floor = Math.Max(end - BackScanBound, start + 1);
                while (probe > floor && !IsWhitespaceElement(chars[probe - 1]))
                {
                    probe--;
                }
                if (probe > floor)
                {
                    end = probe;
                }
            }

            string slice = string.Concat(chars.GetRange(start, end - start)).Trim();
            if (slice.Length != 0)
            {
                drafts.Add(new ChunkDraft(slice, EstimateTokens(slice)));
            }

            if (end >= chars.Count)
            {
                break;
            }
            start = Math.Max(end - overlapChars, start + 1);
        }

        return drafts;
    }

    /// <summary>1 token ~= 4 chars, with a minimum of 1. count is the grapheme-cluster count.</summary>
    public static int EstimateTokens(string text)
    {
        int count = TextElements.Count(text);
        return Math.Max(1, (count + 3) / 4);
    }

    /// <summary>
    /// Like Chunk but takes (text, pageHint) pairs and tags chunks with the page
    /// they came from. Chunks are flattened in page order; ordinals are assigned
    /// later by ReplaceChunks.
    /// </summary>
    public static List<ChunkDraft> ChunkPaged(
        IEnumerable<(string text, int pageHint)> pages,
        int windowChars = 2048,
        int overlapChars = 256)
    {
        var outp = new List<ChunkDraft>();
        foreach (var page in pages)
        {
            foreach (var d in Chunk(page.text, windowChars, overlapChars))
            {
                outp.Add(new ChunkDraft(d.Text, d.TokenCount, page.pageHint));
            }
        }
        return outp;
    }

    // Swift Character.isWhitespace: a grapheme cluster is whitespace when its
    // first scalar is a Unicode whitespace code point. Mirror with char.IsWhiteSpace
    // over the first rune of the element.
    private static bool IsWhitespaceElement(string element)
    {
        if (element.Length == 0)
        {
            return false;
        }
        var runes = element.EnumerateRunes();
        foreach (var r in runes)
        {
            return System.Text.Rune.IsWhiteSpace(r);
        }
        return false;
    }
}
```

- [ ] **Step 6: Run the test (Expected: PASS).**

```
dotnet test windows/tests/AINotebook.Core.Tests --filter "FullyQualifiedName~ChunkerTests"
```
Expected: PASS (5 tests).

- [ ] **Step 7: Commit.**

```
git add windows/src/AINotebook.Core/Ingestion/TextElements.cs windows/src/AINotebook.Core/Ingestion/Chunker.cs windows/tests/AINotebook.Core.Tests/Ingestion/ChunkerTests.cs
git commit -m "feat(core): port Chunker sliding-char-window splitter (grapheme-cluster counting) with verbatim tests

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 15: Extractor contracts + PlainTextExtractor

Create the extractor contract types (`ITextExtractor`, `ExtractedText`, `ExtractorException`) and the first implementation. `PlainTextExtractor` is UTF-8 only (any decode failure → `UnsupportedEncoding`), empty/whitespace-only → `EmptyContent`, markdown title from the first ATX `# ` line (hash + exactly one space) else filename-without-extension; body is preserved verbatim (trimmed, markup not stripped). Port of `TextExtractor.swift` + `PlainTextExtractor.swift`.

**Files:**
- Create: `windows/src/AINotebook.Core/Extractors/ExtractedText.cs`
- Create: `windows/src/AINotebook.Core/Extractors/ExtractorException.cs`
- Create: `windows/src/AINotebook.Core/Extractors/ITextExtractor.cs`
- Create: `windows/src/AINotebook.Core/Extractors/PlainTextExtractor.cs`
- Test: `windows/tests/AINotebook.Core.Tests/Extractors/PlainTextExtractorTests.cs`

- [ ] **Step 1: Write the failing test.** Create `windows/tests/AINotebook.Core.Tests/Extractors/PlainTextExtractorTests.cs` with verbatim assertions ported from `PlainTextExtractorTests.swift`:

```csharp
using System.Text;
using AINotebook.Core.Extractors;
using AINotebook.Core.Models;
using Xunit;

namespace AINotebook.Core.Tests.Extractors;

public class PlainTextExtractorTests : IDisposable
{
    private readonly string _dir;

    public PlainTextExtractorTests()
    {
        _dir = Path.Combine(Path.GetTempPath(), "ai-notebook-tests-" + Guid.NewGuid());
        Directory.CreateDirectory(_dir);
    }

    public void Dispose()
    {
        try { Directory.Delete(_dir, recursive: true); } catch { /* ignore */ }
    }

    private Uri WriteTempFile(string name, byte[] bytes)
    {
        var path = Path.Combine(_dir, name);
        File.WriteAllBytes(path, bytes);
        return new Uri(path);
    }

    [Fact]
    public async Task ExtractsUtf8Plaintext()
    {
        var url = WriteTempFile("memo.txt", Encoding.UTF8.GetBytes("Hello, world."));
        var extracted = await new PlainTextExtractor().ExtractAsync(url, SourceType.Text);
        Assert.Equal("Hello, world.", extracted.Text);
        Assert.Equal("memo", extracted.Title);
    }

    [Fact]
    public async Task StripsMarkdownLeadingHashes()
    {
        const string md = "# Title\n\nSome **bold** body.";
        var url = WriteTempFile("doc.md", Encoding.UTF8.GetBytes(md));
        var extracted = await new PlainTextExtractor().ExtractAsync(url, SourceType.Markdown);
        // Title is the first Markdown heading.
        Assert.Equal("Title", extracted.Title);
        // Markdown body retained (raw text exposed, markup not stripped).
        Assert.Contains("Some **bold** body.", extracted.Text);
    }

    [Fact]
    public async Task EmptyFileThrows()
    {
        var url = WriteTempFile("empty.txt", Array.Empty<byte>());
        await Assert.ThrowsAsync<ExtractorException.EmptyContent>(
            () => new PlainTextExtractor().ExtractAsync(url, SourceType.Text));
    }
}
```

- [ ] **Step 2: Run the test (Expected: FAIL — contract types do not exist).**

```
dotnet test windows/tests/AINotebook.Core.Tests --filter "FullyQualifiedName~PlainTextExtractorTests"
```
Expected: FAIL (compile error).

- [ ] **Step 3: Implement `ExtractedText`.** Create `windows/src/AINotebook.Core/Extractors/ExtractedText.cs`:

```csharp
namespace AINotebook.Core.Extractors;

/// <summary>
/// Result of extraction. PageHints carries one int per PAGE segment (NOT per
/// chunk); null when the extractor cannot determine page boundaries
/// (txt / md / web / Office). 1:1 port of Sources/AINotebookCore/TextExtractor.swift.
/// </summary>
public sealed record ExtractedText(string Title, string Text, int[]? PageHints = null);
```

- [ ] **Step 4: Implement `ExtractorException`.** Create `windows/src/AINotebook.Core/Extractors/ExtractorException.cs`. Model each Swift `ExtractorError` case as a subclass carrying its data so tests assert on type + data:

```csharp
namespace AINotebook.Core.Extractors;

/// <summary>
/// Port of Sources/AINotebookCore/TextExtractor.swift ExtractorError. Each case
/// is a subclass carrying the associated data so tests assert on type + data.
/// </summary>
public abstract class ExtractorException : Exception
{
    protected ExtractorException(string message) : base(message) { }

    public sealed class FileNotReadable : ExtractorException
    {
        public Uri Url { get; }
        public FileNotReadable(Uri url) : base($"File not readable: {url}") => Url = url;
    }

    public sealed class UnsupportedEncoding : ExtractorException
    {
        public Uri Url { get; }
        public UnsupportedEncoding(Uri url) : base($"Unsupported encoding (UTF-8 only): {url}") => Url = url;
    }

    public sealed class EmptyContent : ExtractorException
    {
        public EmptyContent() : base("Extracted content is empty") { }
    }

    public sealed class PdfOpenFailed : ExtractorException
    {
        public Uri Url { get; }
        public PdfOpenFailed(Uri url) : base($"Failed to open PDF: {url}") => Url = url;
    }

    public sealed class OfficeArchiveCorrupt : ExtractorException
    {
        public Uri Url { get; }
        public OfficeArchiveCorrupt(Uri url) : base($"Office archive corrupt: {url}") => Url = url;
    }

    public sealed class WebFetchFailed : ExtractorException
    {
        public Uri Url { get; }
        public int Status { get; }
        public WebFetchFailed(Uri url, int status)
            : base($"Web fetch failed ({status}): {url}")
        {
            Url = url;
            Status = status;
        }
    }

    public sealed class WebResponseNotHtml : ExtractorException
    {
        public Uri Url { get; }
        public string? Mime { get; }
        public WebResponseNotHtml(Uri url, string? mime)
            : base($"Web response not HTML (mime={mime ?? "<none>"}): {url}")
        {
            Url = url;
            Mime = mime;
        }
    }
}
```

- [ ] **Step 5: Implement `ITextExtractor`.** Create `windows/src/AINotebook.Core/Extractors/ITextExtractor.cs`:

```csharp
using AINotebook.Core.Models;

namespace AINotebook.Core.Extractors;

/// <summary>
/// Extract normalized text. kind is the caller's best guess at the source type
/// (the extractor may double-check it). Port of TextExtractor protocol.
/// </summary>
public interface ITextExtractor
{
    Task<ExtractedText> ExtractAsync(Uri url, SourceType kind);
}
```

- [ ] **Step 6: Implement `PlainTextExtractor`.** Create `windows/src/AINotebook.Core/Extractors/PlainTextExtractor.cs`. UTF-8 only via a strict decoder (throws on invalid bytes → `UnsupportedEncoding`); trim; empty → `EmptyContent`; markdown H1 via first `# ` line:

```csharp
using System.Text;
using AINotebook.Core.Models;

namespace AINotebook.Core.Extractors;

/// <summary>1:1 port of Sources/AINotebookCore/PlainTextExtractor.swift. UTF-8 only.</summary>
public sealed class PlainTextExtractor : ITextExtractor
{
    public Task<ExtractedText> ExtractAsync(Uri url, SourceType kind)
    {
        byte[] data;
        try
        {
            data = File.ReadAllBytes(url.LocalPath);
        }
        catch
        {
            throw new ExtractorException.FileNotReadable(url);
        }

        string text;
        try
        {
            // UTF-8 ONLY: throwOnInvalidBytes mirrors String(data:, encoding:.utf8) returning nil.
            var encoding = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);
            text = encoding.GetString(data);
        }
        catch (DecoderFallbackException)
        {
            throw new ExtractorException.UnsupportedEncoding(url);
        }

        string trimmed = text.Trim();
        if (trimmed.Length == 0)
        {
            throw new ExtractorException.EmptyContent();
        }

        string title;
        string? h1 = kind == SourceType.Markdown ? FirstMarkdownHeading(text) : null;
        if (h1 != null)
        {
            title = h1;
        }
        else
        {
            title = Path.GetFileNameWithoutExtension(url.LocalPath);
        }

        return Task.FromResult(new ExtractedText(title, trimmed));
    }

    private static string? FirstMarkdownHeading(string raw)
    {
        foreach (var line in raw.Split('\n', '\r'))
        {
            string t = line.Trim(' ', '\t');
            if (t.StartsWith("# ", StringComparison.Ordinal))
            {
                return t.Substring(2).Trim(' ', '\t');
            }
        }
        return null;
    }
}
```

- [ ] **Step 7: Run the test (Expected: PASS).**

```
dotnet test windows/tests/AINotebook.Core.Tests --filter "FullyQualifiedName~PlainTextExtractorTests"
```
Expected: PASS (3 tests).

- [ ] **Step 8: Commit.**

```
git add windows/src/AINotebook.Core/Extractors/ windows/tests/AINotebook.Core.Tests/Extractors/PlainTextExtractorTests.cs
git commit -m "feat(core): extractor contracts (ITextExtractor/ExtractedText/ExtractorException) + PlainTextExtractor with verbatim tests

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 16: PdfTextExtractor (UglyToad.PdfPig)

Port of `PDFExtractor.swift`. Open via `PdfDocument.Open`; any failure (null/invalid bytes) → `PdfOpenFailed`. Per page, `page.Text` trimmed; skip empty pages; **1-based page hints = original page index + 1** (PdfPig pages are 1-based, so hint = `page.Number`); join non-empty page texts with form-feed `'\f'`; empty joined → `EmptyContent`; title from `document.Information.Title` (when non-empty) else filename-without-extension. The binary fixture `sample.pdf` is copied into the test project.

**Files:**
- Modify: `windows/src/AINotebook.Core/AINotebook.Core.csproj` (add `<PackageReference Include="PdfPig" />`)
- Create: `windows/src/AINotebook.Core/Extractors/PdfTextExtractor.cs`
- Modify: `windows/tests/AINotebook.Core.Tests/AINotebook.Core.Tests.csproj` (copy `Fixtures/**` to output)
- Create (binary copy): `windows/tests/AINotebook.Core.Tests/Fixtures/sample.pdf`
- Test: `windows/tests/AINotebook.Core.Tests/Extractors/PdfTextExtractorTests.cs`

- [ ] **Step 1: Add the PdfPig package and copy the fixture.** Add the package reference to the Core csproj and the fixture copy rule to the test csproj, then copy the binary fixture from the Swift tests directory:

```
dotnet add windows/src/AINotebook.Core package PdfPig --version 0.1.9
```

In `windows/tests/AINotebook.Core.Tests/AINotebook.Core.Tests.csproj`, inside an `<ItemGroup>`, add (this rule covers every fixture for Tasks 16-18):

```xml
  <ItemGroup>
    <None Include="Fixtures\**\*">
      <CopyToOutputDirectory>PreserveNewest</CopyToOutputDirectory>
      <Link>Fixtures\%(RecursiveDir)%(Filename)%(Extension)</Link>
    </None>
  </ItemGroup>
```

Copy the binary fixture verbatim from the canonical Swift tests:

```
mkdir -p windows/tests/AINotebook.Core.Tests/Fixtures
cp Tests/AINotebookCoreTests/Fixtures/sample.pdf windows/tests/AINotebook.Core.Tests/Fixtures/sample.pdf
```

- [ ] **Step 2: Write the failing test.** Create `windows/tests/AINotebook.Core.Tests/Extractors/PdfTextExtractorTests.cs` with verbatim assertions ported from `PDFExtractorTests.swift`:

```csharp
using System.Text;
using AINotebook.Core.Extractors;
using AINotebook.Core.Models;
using Xunit;

namespace AINotebook.Core.Tests.Extractors;

public class PdfTextExtractorTests
{
    private static Uri Fixture(string name) =>
        new Uri(Path.Combine(AppContext.BaseDirectory, "Fixtures", name));

    [Fact]
    public async Task ExtractsTextFromMultiPagePDF()
    {
        var extracted = await new PdfTextExtractor().ExtractAsync(Fixture("sample.pdf"), SourceType.Pdf);
        Assert.Contains("First page text", extracted.Text);
        Assert.Contains("Second page text", extracted.Text);
        Assert.Equal("sample", extracted.Title);
    }

    [Fact]
    public async Task ThrowsOnNonPDF()
    {
        var dir = Path.Combine(Path.GetTempPath(), "notpdf-" + Guid.NewGuid());
        Directory.CreateDirectory(dir);
        var path = Path.Combine(dir, "fake.pdf");
        File.WriteAllBytes(path, Encoding.UTF8.GetBytes("not a pdf"));
        try
        {
            await Assert.ThrowsAsync<ExtractorException.PdfOpenFailed>(
                () => new PdfTextExtractor().ExtractAsync(new Uri(path), SourceType.Pdf));
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }
}
```

- [ ] **Step 3: Run the test (Expected: FAIL — `PdfTextExtractor` does not exist).**

```
dotnet test windows/tests/AINotebook.Core.Tests --filter "FullyQualifiedName~PdfTextExtractorTests"
```
Expected: FAIL (compile error).

- [ ] **Step 4: Implement `PdfTextExtractor`.** Create `windows/src/AINotebook.Core/Extractors/PdfTextExtractor.cs`. Note PdfPig's `page.Number` is already 1-based and equals the Swift `i + 1`; the title attribute maps to `document.Information.Title`:

```csharp
using AINotebook.Core.Models;
using UglyToad.PdfPig;

namespace AINotebook.Core.Extractors;

/// <summary>
/// 1:1 port of Sources/AINotebookCore/PDFExtractor.swift (PDFKit -> PdfPig).
/// Skips empty pages; joins non-empty trimmed page texts with form feed U+000C;
/// page hints are 1-based (PdfPig page.Number == Swift original index + 1).
/// </summary>
public sealed class PdfTextExtractor : ITextExtractor
{
    private const char FormFeed = '\u000C';

    public Task<ExtractedText> ExtractAsync(Uri url, SourceType kind)
    {
        PdfDocument doc;
        try
        {
            doc = PdfDocument.Open(url.LocalPath);
        }
        catch
        {
            throw new ExtractorException.PdfOpenFailed(url);
        }

        using (doc)
        {
            var parts = new List<string>();
            var hints = new List<int>();
            foreach (var page in doc.GetPages())
            {
                string trimmed = page.Text.Trim();
                if (trimmed.Length != 0)
                {
                    parts.Add(trimmed);
                    hints.Add(page.Number); // 1-based, == Swift i + 1
                }
            }

            string joined = string.Join(FormFeed, parts).Trim();
            if (joined.Length == 0)
            {
                throw new ExtractorException.EmptyContent();
            }

            string? infoTitle = doc.Information.Title;
            string title = !string.IsNullOrEmpty(infoTitle)
                ? infoTitle!
                : Path.GetFileNameWithoutExtension(url.LocalPath);

            return Task.FromResult(new ExtractedText(title, joined, hints.ToArray()));
        }
    }
}
```

- [ ] **Step 5: Run the test (Expected: PASS).**

```
dotnet test windows/tests/AINotebook.Core.Tests --filter "FullyQualifiedName~PdfTextExtractorTests"
```
Expected: PASS (2 tests).

- [ ] **Step 6: Commit.**

```
git add windows/src/AINotebook.Core/AINotebook.Core.csproj windows/src/AINotebook.Core/Extractors/PdfTextExtractor.cs windows/tests/AINotebook.Core.Tests/AINotebook.Core.Tests.csproj windows/tests/AINotebook.Core.Tests/Fixtures/sample.pdf windows/tests/AINotebook.Core.Tests/Extractors/PdfTextExtractorTests.cs
git commit -m "feat(core): port PdfTextExtractor (PdfPig) + sample.pdf fixture with verbatim tests

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 17: OfficeTextExtractor (System.IO.Compression + System.Xml)

Port of `OfficeExtractor.swift`. Open the file as a `ZipArchive`; any failure → `OfficeArchiveCorrupt`. Entry selection by kind: `docx → ["word/document.xml"]`; `pptx →` entries whose path starts with `ppt/slides/slide` and ends with `.xml`, sorted with a **plain ordinal string sort** (so `slide10` sorts before `slide2` — do NOT natural-sort); `xlsx → ["xl/sharedStrings.xml"]`. Missing entries are skipped silently; an extract error → `OfficeArchiveCorrupt`. Parse **all** character-data nodes namespace-agnostically (every element's text, in document order), trim each fragment, join non-empty fragments with a single space, collapse `\s+` to one space, trim. Multiple files joined with `"\n\n"`. Empty → `EmptyContent`. Title = filename-without-extension. Each fixture contains the marker `M3 OFFICE TEST DOCUMENT BODY`.

**Files:**
- Create: `windows/src/AINotebook.Core/Extractors/OfficeTextExtractor.cs`
- Create (binary copies): `windows/tests/AINotebook.Core.Tests/Fixtures/sample.docx`, `sample.pptx`, `sample.xlsx`
- Test: `windows/tests/AINotebook.Core.Tests/Extractors/OfficeTextExtractorTests.cs`

(No csproj change — the `Fixtures\**\*` copy rule from Task 16 already covers these.)

- [ ] **Step 1: Copy the binary fixtures.**

```
cp Tests/AINotebookCoreTests/Fixtures/sample.docx windows/tests/AINotebook.Core.Tests/Fixtures/sample.docx
cp Tests/AINotebookCoreTests/Fixtures/sample.pptx windows/tests/AINotebook.Core.Tests/Fixtures/sample.pptx
cp Tests/AINotebookCoreTests/Fixtures/sample.xlsx windows/tests/AINotebook.Core.Tests/Fixtures/sample.xlsx
```

- [ ] **Step 2: Write the failing test.** Create `windows/tests/AINotebook.Core.Tests/Extractors/OfficeTextExtractorTests.cs` with verbatim assertions ported from `OfficeExtractorTests.swift`:

```csharp
using System.Text;
using AINotebook.Core.Extractors;
using AINotebook.Core.Models;
using Xunit;

namespace AINotebook.Core.Tests.Extractors;

public class OfficeTextExtractorTests
{
    private const string Marker = "M3 OFFICE TEST DOCUMENT BODY";

    private static Uri Fixture(string name) =>
        new Uri(Path.Combine(AppContext.BaseDirectory, "Fixtures", name));

    [Fact]
    public async Task ExtractsDocxBodyText()
    {
        var extracted = await new OfficeTextExtractor().ExtractAsync(Fixture("sample.docx"), SourceType.Docx);
        Assert.Contains(Marker, extracted.Text);
        Assert.NotEqual(string.Empty, extracted.Text);
    }

    [Fact]
    public async Task ExtractsPptxSlideText()
    {
        var extracted = await new OfficeTextExtractor().ExtractAsync(Fixture("sample.pptx"), SourceType.Pptx);
        Assert.Contains(Marker, extracted.Text);
    }

    [Fact]
    public async Task ExtractsXlsxSharedStrings()
    {
        var extracted = await new OfficeTextExtractor().ExtractAsync(Fixture("sample.xlsx"), SourceType.Xlsx);
        Assert.Contains(Marker, extracted.Text);
    }

    [Fact]
    public async Task CorruptArchiveThrows()
    {
        var dir = Path.Combine(Path.GetTempPath(), "notzip-" + Guid.NewGuid());
        Directory.CreateDirectory(dir);
        var path = Path.Combine(dir, "fake.docx");
        File.WriteAllBytes(path, Encoding.UTF8.GetBytes("not a zip"));
        try
        {
            await Assert.ThrowsAsync<ExtractorException.OfficeArchiveCorrupt>(
                () => new OfficeTextExtractor().ExtractAsync(new Uri(path), SourceType.Docx));
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }
}
```

- [ ] **Step 3: Run the test (Expected: FAIL — `OfficeTextExtractor` does not exist).**

```
dotnet test windows/tests/AINotebook.Core.Tests --filter "FullyQualifiedName~OfficeTextExtractorTests"
```
Expected: FAIL (compile error).

- [ ] **Step 4: Implement `OfficeTextExtractor`.** Create `windows/src/AINotebook.Core/Extractors/OfficeTextExtractor.cs`. Use `ZipFile.OpenRead` (System.IO.Compression, in `System.IO.Compression.FileSystem` / built into .NET 8) and an `XmlReader` SAX-style harvest of all `Text`/`CDATA`/`SignificantWhitespace`/`Whitespace` nodes. **Note on pptx sort:** `StringComparer.Ordinal` reproduces the Swift `.sorted()` lexicographic order (`slide10.xml` before `slide2.xml`):

```csharp
using System.IO.Compression;
using System.Text;
using System.Text.RegularExpressions;
using System.Xml;
using AINotebook.Core.Models;

namespace AINotebook.Core.Extractors;

/// <summary>
/// 1:1 port of Sources/AINotebookCore/OfficeExtractor.swift (ZIPFoundation + XMLParser
/// -> System.IO.Compression + System.Xml). Harvests ALL character-data nodes
/// namespace-agnostically; pptx slides sorted with PLAIN ordinal sort (slide10 before slide2).
/// </summary>
public sealed class OfficeTextExtractor : ITextExtractor
{
    private static readonly Regex WhitespaceRun = new(@"\s+", RegexOptions.Compiled);

    public Task<ExtractedText> ExtractAsync(Uri url, SourceType kind)
    {
        ZipArchive archive;
        try
        {
            archive = ZipFile.OpenRead(url.LocalPath);
        }
        catch
        {
            throw new ExtractorException.OfficeArchiveCorrupt(url);
        }

        using (archive)
        {
            IReadOnlyList<string> xmlPaths = kind switch
            {
                SourceType.Docx => new[] { "word/document.xml" },
                SourceType.Pptx => SlidePaths(archive),
                SourceType.Xlsx => new[] { "xl/sharedStrings.xml" },
                _ => throw new ExtractorException.OfficeArchiveCorrupt(url),
            };

            var collected = new List<string>();
            foreach (var path in xmlPaths)
            {
                var entry = archive.GetEntry(path);
                if (entry == null)
                {
                    continue; // missing entry skipped silently
                }

                byte[] bytes;
                try
                {
                    using var s = entry.Open();
                    using var ms = new MemoryStream();
                    s.CopyTo(ms);
                    bytes = ms.ToArray();
                }
                catch
                {
                    throw new ExtractorException.OfficeArchiveCorrupt(url);
                }

                string text = ParseXmlTextNodes(bytes);
                if (text.Length != 0)
                {
                    collected.Add(text);
                }
            }

            string joined = string.Join("\n\n", collected).Trim();
            if (joined.Length == 0)
            {
                throw new ExtractorException.EmptyContent();
            }

            string title = Path.GetFileNameWithoutExtension(url.LocalPath);
            return Task.FromResult(new ExtractedText(title, joined));
        }
    }

    /// <summary>
    /// pptx stores each slide as ppt/slides/slideN.xml. Enumerate them and sort
    /// with a PLAIN ordinal string sort to match Swift's .sorted() exactly
    /// (slide10.xml sorts before slide2.xml — do NOT natural-sort).
    /// </summary>
    private static List<string> SlidePaths(ZipArchive archive)
    {
        var paths = new List<string>();
        foreach (var entry in archive.Entries)
        {
            string p = entry.FullName;
            if (p.StartsWith("ppt/slides/slide", StringComparison.Ordinal)
                && p.EndsWith(".xml", StringComparison.Ordinal))
            {
                paths.Add(p);
            }
        }
        paths.Sort(StringComparer.Ordinal);
        return paths;
    }

    /// <summary>
    /// SAX-style harvest of every character-data node. Trim each fragment, keep
    /// non-empty, join with single space, collapse \s+ to one space, trim.
    /// </summary>
    internal static string ParseXmlTextNodes(byte[] data)
    {
        var fragments = new List<string>();
        var settings = new XmlReaderSettings
        {
            DtdProcessing = DtdProcessing.Ignore,
            IgnoreComments = true,
            IgnoreProcessingInstructions = true,
        };
        using var ms = new MemoryStream(data);
        using var reader = XmlReader.Create(ms, settings);
        while (reader.Read())
        {
            if (reader.NodeType is XmlNodeType.Text
                or XmlNodeType.CDATA
                or XmlNodeType.SignificantWhitespace
                or XmlNodeType.Whitespace)
            {
                string t = reader.Value.Trim();
                if (t.Length != 0)
                {
                    fragments.Add(t);
                }
            }
        }

        string joined = string.Join(" ", fragments);
        return WhitespaceRun.Replace(joined, " ").Trim();
    }
}
```

- [ ] **Step 5: Run the test (Expected: PASS).**

```
dotnet test windows/tests/AINotebook.Core.Tests --filter "FullyQualifiedName~OfficeTextExtractorTests"
```
Expected: PASS (4 tests).

- [ ] **Step 6: Commit.**

```
git add windows/src/AINotebook.Core/Extractors/OfficeTextExtractor.cs windows/tests/AINotebook.Core.Tests/Fixtures/sample.docx windows/tests/AINotebook.Core.Tests/Fixtures/sample.pptx windows/tests/AINotebook.Core.Tests/Fixtures/sample.xlsx windows/tests/AINotebook.Core.Tests/Extractors/OfficeTextExtractorTests.cs
git commit -m "feat(core): port OfficeTextExtractor (ZipArchive + XmlReader, ordinal pptx sort) + fixtures with verbatim tests

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 18: WebTextExtractor (HttpClient + AngleSharp) + IngestionService

Two units that complete the ingestion layer. (`NoteIndexer` ships in Task 25 under `AINotebook.Core.Rag`.)

**WebTextExtractor** (port of `WebExtractor.swift`): GET the URL; non-HTTP response → `WebFetchFailed(status: 0)`; non-2xx → `WebFetchFailed(code)`; `Content-Type` must contain `text/html` (case-insensitive) else `WebResponseNotHtml`; parse with AngleSharp; **remove** tags in order `[script, style, nav, footer, aside, header, noscript, form]` globally before root selection; root priority first `<article>` → first `<main>` → `<body>` → else `EmptyContent`; `TextContent` normalized (AngleSharp does NOT collapse whitespace, so collapse runs of whitespace to a single space and trim — to match SwiftSoup `.text()`); empty → `EmptyContent`; title = `<title>` (when non-empty) else host else `"Web source"`.

**IngestionService** (port of `IngestionService.swift`): `IngestFileAsync` detects type and throws `IngestionException.UnsupportedExtension` **before** creating any row; otherwise creates the source (status `Pending` set by `CreateSource`), then runs the pipeline (status → `Chunking`, extract+chunk, `ReplaceChunks` + status `Ready`, await `onChunksWritten`; on any throw set status `Error` with `ex.ToString()` and rethrow). PDF splits `extracted.Text` on `'\f'` (keeping empty segments) and zips with `PageHints` into `ChunkPaged`. `IngestRawTextAsync` (type `Text`). `IngestUrlAsync` (type `Web`, title = host).

(`NoteIndexer` — the `type='note'` shadow-source indexer — is implemented in Task 25 under `AINotebook.Core.Rag`, not here.)

**Files:**
- Modify: `windows/src/AINotebook.Core/AINotebook.Core.csproj` (add `<PackageReference Include="AngleSharp" />`)
- Create: `windows/src/AINotebook.Core/Extractors/WebTextExtractor.cs`
- Create: `windows/src/AINotebook.Core/Ingestion/IngestionException.cs`
- Create: `windows/src/AINotebook.Core/Ingestion/IngestionService.cs`
- Create (binary copy): `windows/tests/AINotebook.Core.Tests/Fixtures/sample.html`
- Test: `windows/tests/AINotebook.Core.Tests/Extractors/WebTextExtractorTests.cs`
- Test: `windows/tests/AINotebook.Core.Tests/Ingestion/IngestionServiceTests.cs`

> Dependencies (provided by other writers per the SHARED TYPE CONTRACT): `NotebookStore` with `CreateSource`, `UpdateSourceStatus`, `ReplaceChunks`, `Chunks`, `Sources`, `Source`, `Note`/`CreateNote`/`UpdateNote`/`Note(id)`, and `LinkNoteToShadowSource`. Use those names verbatim. `SourceStatus.Pending/Chunking/Ready/Error`, `SourceType.Pdf/Text/Markdown/Web/Docx/Pptx/Xlsx/Note`, `StoreException`.

- [ ] **Step 1: Add AngleSharp and copy the HTML fixture.**

```
dotnet add windows/src/AINotebook.Core package AngleSharp --version 1.1.2
cp Tests/AINotebookCoreTests/Fixtures/sample.html windows/tests/AINotebook.Core.Tests/Fixtures/sample.html
```

The `sample.html` fixture content (for reference — copy the binary verbatim, do not retype):

```html
<!DOCTYPE html>
<html>
<head><title>Sample Article</title></head>
<body>
  <nav>Site nav (should be stripped)</nav>
  <article>
    <h1>Sample Article</h1>
    <p>This is the main article body. It has <a href="#">a link</a> inside it.</p>
    <p>Another paragraph.</p>
    <script>console.log("never extract me")</script>
  </article>
  <footer>Copyright (should be stripped)</footer>
</body>
</html>
```

- [ ] **Step 2: Write the failing WebTextExtractor test.** Create `windows/tests/AINotebook.Core.Tests/Extractors/WebTextExtractorTests.cs` with verbatim assertions ported from `WebExtractorTests.swift` (the parse path is tested directly via the internal static `ParseHtml`, no network stub needed):

```csharp
using AINotebook.Core.Extractors;
using Xunit;

namespace AINotebook.Core.Tests.Extractors;

public class WebTextExtractorTests
{
    [Fact]
    public void ExtractsArticleBodyAndTitleFromHtml()
    {
        var path = Path.Combine(AppContext.BaseDirectory, "Fixtures", "sample.html");
        string html = File.ReadAllText(path);
        var extracted = WebTextExtractor.ParseHtml(html, new Uri("https://example.com/a"));
        Assert.Equal("Sample Article", extracted.Title);
        Assert.Contains("main article body", extracted.Text);
        Assert.Contains("Another paragraph", extracted.Text);
        Assert.DoesNotContain("never extract me", extracted.Text); // script stripped
        Assert.DoesNotContain("Site nav", extracted.Text);          // nav stripped
        Assert.DoesNotContain("Copyright", extracted.Text);         // footer stripped
    }

    [Fact]
    public void ParseHtmlThrowsOnEmptyBody()
    {
        const string html = "<html><head><title>T</title></head><body></body></html>";
        Assert.Throws<ExtractorException.EmptyContent>(
            () => WebTextExtractor.ParseHtml(html, new Uri("https://example.com")));
    }
}
```

- [ ] **Step 3: Run the test (Expected: FAIL — `WebTextExtractor` does not exist).**

```
dotnet test windows/tests/AINotebook.Core.Tests --filter "FullyQualifiedName~WebTextExtractorTests"
```
Expected: FAIL (compile error).

- [ ] **Step 4: Implement `WebTextExtractor`.** Create `windows/src/AINotebook.Core/Extractors/WebTextExtractor.cs`. AngleSharp's `HtmlParser` parses synchronously; whitespace is collapsed manually because AngleSharp's `TextContent` preserves it (gotcha 13):

```csharp
using System.Text.RegularExpressions;
using AINotebook.Core.Models;
using AngleSharp.Dom;
using AngleSharp.Html.Parser;

namespace AINotebook.Core.Extractors;

/// <summary>
/// 1:1 port of Sources/AINotebookCore/WebExtractor.swift (URLSession + SwiftSoup
/// -> HttpClient + AngleSharp). Network fetch + content-type guard, then a pure,
/// network-free ParseHtml (tested directly).
/// </summary>
public sealed class WebTextExtractor : ITextExtractor
{
    private static readonly string[] StripTags =
        { "script", "style", "nav", "footer", "aside", "header", "noscript", "form" };
    private static readonly Regex WhitespaceRun = new(@"\s+", RegexOptions.Compiled);

    private readonly HttpClient _http;

    public WebTextExtractor(HttpClient? http = null)
    {
        _http = http ?? new HttpClient();
    }

    public async Task<ExtractedText> ExtractAsync(Uri url, SourceType kind)
    {
        HttpResponseMessage response;
        try
        {
            response = await _http.GetAsync(url);
        }
        catch
        {
            // No HTTP response at all (connection failure) -> status 0.
            throw new ExtractorException.WebFetchFailed(url, 0);
        }

        using (response)
        {
            int code = (int)response.StatusCode;
            if (code < 200 || code >= 300)
            {
                throw new ExtractorException.WebFetchFailed(url, code);
            }

            string? mime = response.Content.Headers.ContentType?.ToString();
            if (!(mime ?? string.Empty).ToLowerInvariant().Contains("text/html"))
            {
                throw new ExtractorException.WebResponseNotHtml(url, mime);
            }

            string html = await response.Content.ReadAsStringAsync();
            return ParseHtml(html, url);
        }
    }

    /// <summary>Pure HTML -> ExtractedText. Network-free; tested directly.</summary>
    public static ExtractedText ParseHtml(string html, Uri sourceUrl)
    {
        var parser = new HtmlParser();
        IDocument doc = parser.ParseDocument(html);

        // Remove non-content elements before reading the body, in this exact order.
        foreach (var tag in StripTags)
        {
            foreach (var el in doc.QuerySelectorAll(tag).ToArray())
            {
                el.Remove();
            }
        }

        // Prefer <article> when present, otherwise <main>, otherwise <body>.
        IElement? root = doc.QuerySelector("article")
            ?? doc.QuerySelector("main")
            ?? doc.Body;
        if (root == null)
        {
            throw new ExtractorException.EmptyContent();
        }

        // AngleSharp's TextContent does NOT collapse whitespace; collapse runs to a
        // single space and trim to match SwiftSoup .text().
        string text = WhitespaceRun.Replace(root.TextContent, " ").Trim();
        if (text.Length == 0)
        {
            throw new ExtractorException.EmptyContent();
        }

        string docTitle = doc.Title ?? string.Empty;
        string title = docTitle.Length == 0
            ? (sourceUrl.Host.Length != 0 ? sourceUrl.Host : "Web source")
            : docTitle;

        return new ExtractedText(title, text);
    }
}
```

- [ ] **Step 5: Run the WebTextExtractor test (Expected: PASS).**

```
dotnet test windows/tests/AINotebook.Core.Tests --filter "FullyQualifiedName~WebTextExtractorTests"
```
Expected: PASS (2 tests).

- [ ] **Step 6: Implement `IngestionException`.** Create `windows/src/AINotebook.Core/Ingestion/IngestionException.cs`:

```csharp
namespace AINotebook.Core.Ingestion;

/// <summary>Port of IngestionService.IngestionError.</summary>
public abstract class IngestionException : Exception
{
    protected IngestionException(string message) : base(message) { }

    public sealed class UnsupportedExtension : IngestionException
    {
        public string Extension { get; }
        public UnsupportedExtension(string extension)
            : base($"Unsupported extension: {extension}") => Extension = extension;
    }
}
```

- [ ] **Step 7: Write the failing IngestionService test.** Create `windows/tests/AINotebook.Core.Tests/Ingestion/IngestionServiceTests.cs` with verbatim assertions ported from `IngestionServiceTests.swift`:

```csharp
using AINotebook.Core;
using AINotebook.Core.Ingestion;
using AINotebook.Core.Models;
using Xunit;

namespace AINotebook.Core.Tests.Ingestion;

public class IngestionServiceTests
{
    [Fact]
    public async Task IngestPlainTextEndToEnd()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("NB");

        var dir = Path.Combine(Path.GetTempPath(), "ing-" + Guid.NewGuid());
        Directory.CreateDirectory(dir);
        try
        {
            var file = Path.Combine(dir, "memo.txt");
            File.WriteAllText(file, "Hello world. Second sentence.");

            var service = new IngestionService(store);
            var source = await service.IngestFileAsync(new Uri(file), nb.Id!.Value);

            // Refresh status from disk.
            var reloaded = store.Source(source.Id!.Value);
            Assert.NotNull(reloaded);
            Assert.Equal(SourceStatus.Ready, reloaded!.Status);
            Assert.Equal(SourceType.Text, reloaded.Type);
            Assert.Equal("memo", reloaded.Title);

            var chunks = store.Chunks(source.Id!.Value);
            Assert.True(chunks.Count > 0);
            Assert.Equal(0, chunks[0].Ord);
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }

    [Fact]
    public async Task IngestRawTextCreatesPersistedSource()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("NB");

        var service = new IngestionService(store);
        var source = await service.IngestRawTextAsync(
            "My note",
            string.Concat(Enumerable.Repeat("lorem ipsum ", 500)),
            nb.Id!.Value);

        Assert.Equal(SourceStatus.Ready, source.Status);
        Assert.Equal(SourceType.Text, source.Type);
        var chunks = store.Chunks(source.Id!.Value);
        Assert.True(chunks.Count > 1);
    }

    [Fact]
    public async Task IngestUnknownExtensionLeavesNoSourceRow()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("NB");

        var dir = Path.Combine(Path.GetTempPath(), "ing-" + Guid.NewGuid());
        Directory.CreateDirectory(dir);
        try
        {
            var file = Path.Combine(dir, "mystery.bin");
            File.WriteAllBytes(file, new byte[] { 0x01, 0x02, 0x03 });

            var service = new IngestionService(store);
            await Assert.ThrowsAsync<IngestionException.UnsupportedExtension>(
                () => service.IngestFileAsync(new Uri(file), nb.Id!.Value));

            // No source row should have been created.
            Assert.Empty(store.Sources(nb.Id!.Value));
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }
}
```

- [ ] **Step 8: Implement `IngestionService`.** Create `windows/src/AINotebook.Core/Ingestion/IngestionService.cs`. Port the pipeline order and per-type dispatch from `IngestionService.swift` lines 40-141. PDF segment split keeps empty segments (`StringSplitOptions.None`) and zips with `PageHints` (shorter wins, matching Swift `zip`):

```csharp
using AINotebook.Core.Extractors;
using AINotebook.Core.Models;

namespace AINotebook.Core.Ingestion;

/// <summary>
/// Orchestrates: type-detect -> text-extract -> chunk -> persist, updating the
/// source's status row at every stage. 1:1 port of Sources/AINotebookCore/IngestionService.swift.
/// Embedding is NOT enqueued inline: after ReplaceChunks + status Ready, the
/// onChunksWritten callback fires; a separate Embedder/EmbeddingWorker drains
/// the unembedded-chunks queue.
/// </summary>
public sealed class IngestionService
{
    private const char FormFeed = '\u000C';

    private readonly NotebookStore _store;
    private readonly ITextExtractor _plain;
    private readonly ITextExtractor _pdf;
    private readonly ITextExtractor _web;
    private readonly ITextExtractor _office;
    private readonly Func<Task>? _onChunksWritten;

    public IngestionService(
        NotebookStore store,
        ITextExtractor? plain = null,
        ITextExtractor? pdf = null,
        ITextExtractor? web = null,
        ITextExtractor? office = null,
        Func<Task>? onChunksWritten = null)
    {
        _store = store;
        _plain = plain ?? new PlainTextExtractor();
        _pdf = pdf ?? new PdfTextExtractor();
        _web = web ?? new WebTextExtractor();
        _office = office ?? new OfficeTextExtractor();
        _onChunksWritten = onChunksWritten;
    }

    public async Task<Source> IngestFileAsync(Uri url, long notebookId)
    {
        string filename = Path.GetFileName(url.LocalPath);
        SourceType? kind = SourceTypeExtensions.Detect(filename);
        if (kind == null)
        {
            // Throw BEFORE creating any source row.
            throw new IngestionException.UnsupportedExtension(
                Path.GetExtension(url.LocalPath).TrimStart('.'));
        }

        string title = Path.GetFileNameWithoutExtension(url.LocalPath);
        var source = _store.CreateSource(notebookId, kind.Value, title, uri: null, rawPath: url.LocalPath);

        return await RunPipelineAsync(source, async () =>
        {
            switch (kind.Value)
            {
                case SourceType.Pdf:
                {
                    var extracted = await _pdf.ExtractAsync(url, kind.Value);
                    List<(string text, int pageHint)> pages;
                    if (extracted.PageHints != null)
                    {
                        // Split on form feed, keeping empty segments, then zip with hints (shorter wins).
                        var split = extracted.Text.Split(FormFeed);
                        var hints = extracted.PageHints;
                        int n = Math.Min(split.Length, hints.Length);
                        pages = new List<(string, int)>(n);
                        for (int i = 0; i < n; i++)
                        {
                            pages.Add((split[i], hints[i]));
                        }
                    }
                    else
                    {
                        pages = new List<(string, int)> { (extracted.Text, 0) };
                    }
                    return (extracted, Chunker.ChunkPaged(pages));
                }
                case SourceType.Text:
                case SourceType.Markdown:
                {
                    var e = await _plain.ExtractAsync(url, kind.Value);
                    return (e, Chunker.Chunk(e.Text));
                }
                case SourceType.Docx:
                case SourceType.Pptx:
                case SourceType.Xlsx:
                {
                    var e = await _office.ExtractAsync(url, kind.Value);
                    return (e, Chunker.Chunk(e.Text));
                }
                case SourceType.Web:
                {
                    var e = await _web.ExtractAsync(url, kind.Value);
                    return (e, Chunker.Chunk(e.Text));
                }
                default: // Note: managed via Notebook notes, not file ingestion.
                    throw new IngestionException.UnsupportedExtension(
                        Path.GetExtension(url.LocalPath).TrimStart('.'));
            }
        });
    }

    public async Task<Source> IngestRawTextAsync(string title, string text, long notebookId)
    {
        var source = _store.CreateSource(notebookId, SourceType.Text, title, uri: null, rawPath: null);
        return await RunPipelineAsync(source, () =>
        {
            var e = new ExtractedText(title, text);
            return Task.FromResult((e, Chunker.Chunk(text)));
        });
    }

    public async Task<Source> IngestUrlAsync(Uri url, long notebookId)
    {
        string title = url.Host.Length != 0 ? url.Host : url.AbsoluteUri;
        var source = _store.CreateSource(notebookId, SourceType.Web, title, uri: url.AbsoluteUri, rawPath: null);
        return await RunPipelineAsync(source, async () =>
        {
            var e = await _web.ExtractAsync(url, SourceType.Web);
            return (e, Chunker.Chunk(e.Text));
        });
    }

    private async Task<Source> RunPipelineAsync(
        Source sourceIn,
        Func<Task<(ExtractedText, List<ChunkDraft>)>> extract)
    {
        var source = sourceIn;
        try
        {
            _store.UpdateSourceStatus(source.Id!.Value, SourceStatus.Chunking, error: null);
            var (_, chunks) = await extract();
            _store.ReplaceChunks(source.Id!.Value, chunks);
            _store.UpdateSourceStatus(source.Id!.Value, SourceStatus.Ready, error: null);
            if (_onChunksWritten != null)
            {
                await _onChunksWritten();
            }
            return source with { Status = SourceStatus.Ready };
        }
        catch (Exception ex)
        {
            string message = ex.ToString();
            try
            {
                _store.UpdateSourceStatus(source.Id!.Value, SourceStatus.Error, error: message);
            }
            catch
            {
                // best-effort: mirror Swift `try?`
            }
            throw;
        }
    }
}
```

> `NoteIndexer` is implemented in Task 25 (namespace `AINotebook.Core.Rag`), not here — it belongs with the RAG/note pipeline and depends on `NotebookStore.UpdateSourceTitle` (Task 7) + `LinkNoteToShadowSource`. Task 18 covers only `WebTextExtractor` + `IngestionService`.

- [ ] **Step 11: Run all Task-18 tests (Expected: PASS).**

```
dotnet test windows/tests/AINotebook.Core.Tests --filter "FullyQualifiedName~WebTextExtractorTests|FullyQualifiedName~IngestionServiceTests"
```
Expected: PASS (WebTextExtractor 2, IngestionService 3).

- [ ] **Step 12: Commit.**

```
git add windows/src/AINotebook.Core/AINotebook.Core.csproj windows/src/AINotebook.Core/Extractors/WebTextExtractor.cs windows/src/AINotebook.Core/Ingestion/IngestionException.cs windows/src/AINotebook.Core/Ingestion/IngestionService.cs windows/tests/AINotebook.Core.Tests/Fixtures/sample.html windows/tests/AINotebook.Core.Tests/Extractors/WebTextExtractorTests.cs windows/tests/AINotebook.Core.Tests/Ingestion/IngestionServiceTests.cs
git commit -m "feat(core): port WebTextExtractor (AngleSharp) + IngestionService with verbatim tests

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 19: Ollama wire DTOs + `StubHttpMessageHandler` test helper

Ports `OllamaChatTypes.swift`, `OllamaEmbedTypes.swift`, `OllamaModel.swift`, `OllamaPullEvent.swift`, `OllamaError.swift`, and the `ChatTurn`/`ChatStreaming` protocol surface. JSON mapping is **per-DTO** (`[JsonPropertyName]` on snake_case fields only — there is NO global naming policy), `created_at`/`modified_at` stay raw strings, `OllamaChatRequest.Options` omits nulls, and `OllamaEmbedRequest.input` is always an array. The `StubHttpMessageHandler` is the .NET equivalent of `StubURLProtocol`: a thread-safe FIFO queue of canned responses with `.Json` / `.Ndjson` / `.ConnectionRefused` factories, recording the last request.

**Files:**
- Create: `windows/src/AINotebook.Core/Ollama/OllamaDtos.cs`
- Create: `windows/src/AINotebook.Core/Ollama/OllamaException.cs`
- Create: `windows/src/AINotebook.Core/Ollama/ChatTurn.cs`
- Create: `windows/tests/AINotebook.Core.Tests/Helpers/StubHttpMessageHandler.cs`
- Test: `windows/tests/AINotebook.Core.Tests/Ollama/OllamaWireTypesTests.cs`
- Test: `windows/tests/AINotebook.Core.Tests/Ollama/OllamaPullEventTests.cs`
- Test: `windows/tests/AINotebook.Core.Tests/Ollama/OllamaModelTests.cs`

- [ ] **Step 1: Write failing wire-type + pull-event + model-list tests.**

`windows/tests/AINotebook.Core.Tests/Ollama/OllamaWireTypesTests.cs`:
```csharp
using System.Text.Json;
using AINotebook.Core.Ollama;
using Xunit;

namespace AINotebook.Core.Tests.Ollama;

public class OllamaWireTypesTests
{
    private static readonly JsonSerializerOptions Opts = OllamaJson.Options;

    // OllamaWireTypesTests.testChatRequestEncodes
    [Fact]
    public void ChatRequestEncodesStreamTrueAndMessages()
    {
        var req = new OllamaChatRequest(
            "llama3.2:3b",
            new[]
            {
                new OllamaChatMessage(OllamaChatRole.System, "be brief"),
                new OllamaChatMessage(OllamaChatRole.User, "hi"),
            },
            stream: true,
            options: null);

        var json = JsonSerializer.Serialize(req, Opts);
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;

        Assert.Equal("llama3.2:3b", root.GetProperty("model").GetString());
        Assert.True(root.GetProperty("stream").GetBoolean());
        Assert.Equal(2, root.GetProperty("messages").GetArrayLength());
        Assert.Equal("system", root.GetProperty("messages")[0].GetProperty("role").GetString());
        // options is null -> omitted entirely
        Assert.False(root.TryGetProperty("options", out _));
    }

    // OllamaWireTypesTests.testChatChunkDecode (validates created_at maps)
    [Fact]
    public void ChatChunkDecodesCreatedAtAndMessage()
    {
        const string json = """
        {"model":"llama3.2:3b","created_at":"2024-09-25T12:00:00Z","message":{"role":"assistant","content":"Hi"},"done":false}
        """;
        var chunk = JsonSerializer.Deserialize<OllamaChatChunk>(json, Opts)!;
        Assert.Equal("Hi", chunk.Message.Content);
        Assert.Equal(OllamaChatRole.Assistant, chunk.Message.Role);
        Assert.False(chunk.Done);
        Assert.Equal("2024-09-25T12:00:00Z", chunk.CreatedAt);
    }

    // OllamaWireTypesTests.testEmbedRequestEncodesArrayInput
    [Fact]
    public void EmbedRequestEncodesArrayInput()
    {
        var req = new OllamaEmbedRequest("nomic-embed-text", new[] { "a", "b" });
        var json = JsonSerializer.Serialize(req, Opts);
        using var doc = JsonDocument.Parse(json);
        Assert.Equal("nomic-embed-text", doc.RootElement.GetProperty("model").GetString());
        var input = doc.RootElement.GetProperty("input");
        Assert.Equal(JsonValueKind.Array, input.ValueKind);
        Assert.Equal("a", input[0].GetString());
        Assert.Equal("b", input[1].GetString());
    }

    // OllamaWireTypesTests.testEmbedResponseDecodes
    [Fact]
    public void EmbedResponseDecodesNestedDoubleArray()
    {
        const string json = """{"embeddings":[[0.1,0.2,0.3],[0.4,0.5,0.6]]}""";
        var resp = JsonSerializer.Deserialize<OllamaEmbedResponse>(json, Opts)!;
        Assert.Equal(2, resp.Embeddings.Length);
        Assert.Equal(new[] { 0.1, 0.2, 0.3 }, resp.Embeddings[0]);
    }
}
```

`windows/tests/AINotebook.Core.Tests/Ollama/OllamaPullEventTests.cs`:
```csharp
using System.Text.Json;
using AINotebook.Core.Ollama;
using Xunit;

namespace AINotebook.Core.Tests.Ollama;

public class OllamaPullEventTests
{
    private static readonly JsonSerializerOptions Opts = OllamaJson.Options;

    // OllamaPullEventTests.testDecodeStartStatus
    [Fact]
    public void DecodeStartStatusLeavesProgressNull()
    {
        var ev = JsonSerializer.Deserialize<OllamaPullEvent>("""{"status":"pulling manifest"}""", Opts)!;
        Assert.Equal("pulling manifest", ev.Status);
        Assert.Null(ev.Total);
        Assert.Null(ev.Completed);
        Assert.Null(ev.Digest);
    }

    // OllamaPullEventTests.testDecodeProgressEvent
    [Fact]
    public void DecodeProgressEventComputesFraction()
    {
        const string json = """
        {"status":"downloading","digest":"sha256:abc","total":2019377664,"completed":1000000}
        """;
        var ev = JsonSerializer.Deserialize<OllamaPullEvent>(json, Opts)!;
        Assert.Equal("downloading", ev.Status);
        Assert.Equal("sha256:abc", ev.Digest);
        Assert.Equal(2019377664L, ev.Total);
        Assert.Equal(1000000L, ev.Completed);
        Assert.NotNull(ev.FractionComplete);
        Assert.Equal(1000000.0 / 2019377664.0, ev.FractionComplete!.Value, 9);
    }

    // OllamaPullEventTests.testFractionCompleteIsNilWhenMissing
    [Fact]
    public void FractionCompleteNullWhenFieldsMissing()
    {
        var ev = JsonSerializer.Deserialize<OllamaPullEvent>("""{"status":"verifying"}""", Opts)!;
        Assert.Null(ev.FractionComplete);
    }

    // OllamaPullEventTests.testIsTerminalSuccess
    [Fact]
    public void IsTerminalSuccessOnlyForSuccessStatus()
    {
        Assert.True(new OllamaPullEvent("success").IsTerminalSuccess);
        Assert.False(new OllamaPullEvent("downloading").IsTerminalSuccess);
    }
}
```

`windows/tests/AINotebook.Core.Tests/Ollama/OllamaModelTests.cs`:
```csharp
using System.Text.Json;
using AINotebook.Core.Ollama;
using Xunit;

namespace AINotebook.Core.Tests.Ollama;

public class OllamaModelTests
{
    private static readonly JsonSerializerOptions Opts = OllamaJson.Options;

    // OllamaModelTests.testDecodesTagListPayload
    [Fact]
    public void DecodesTagListPayload()
    {
        const string json = """
        {"models":[{"name":"llama3.2:3b","modified_at":"2024-09-25T12:00:00Z","size":2019377664,"digest":"abc123","details":{"format":"gguf","family":"llama","parameter_size":"3B","quantization_level":"Q4_K_M"}}]}
        """;
        var list = JsonSerializer.Deserialize<OllamaModelList>(json, Opts)!;
        Assert.Single(list.Models);
        var m = list.Models[0];
        Assert.Equal("llama3.2:3b", m.Name);
        Assert.Equal(2019377664L, m.Size);
        Assert.Equal("abc123", m.Digest);
        Assert.Equal("3B", m.Details.ParameterSize);
        Assert.Equal("2024-09-25T12:00:00Z", m.ModifiedAt);
    }

    // OllamaModelTests.testEmptyListDecodes
    [Fact]
    public void EmptyListDecodes()
    {
        var list = JsonSerializer.Deserialize<OllamaModelList>("""{"models":[]}""", Opts)!;
        Assert.Empty(list.Models);
    }
}
```

- [ ] **Step 2: Run the tests — Expected: FAIL (DTOs do not exist).**
```
dotnet test windows/tests/AINotebook.Core.Tests --filter "FullyQualifiedName~Ollama.OllamaWireTypesTests|FullyQualifiedName~Ollama.OllamaPullEventTests|FullyQualifiedName~Ollama.OllamaModelTests"
```
Expected: FAIL (compile error — `OllamaChatRequest`, `OllamaJson`, etc. are undefined).

- [ ] **Step 3: Implement `OllamaException`.**

`windows/src/AINotebook.Core/Ollama/OllamaException.cs` (ports `OllamaError.swift`; tests pattern-match on the `Code` of `HttpStatus`):
```csharp
namespace AINotebook.Core.Ollama;

public abstract class OllamaException : Exception
{
    protected OllamaException(string message) : base(message) { }

    public sealed class NotReachable : OllamaException
    {
        public NotReachable() : base("Ollama daemon is not reachable on localhost:11434.") { }
    }

    public sealed class Timeout : OllamaException
    {
        public Timeout() : base("Ollama request timed out.") { }
    }

    public sealed class HttpStatus : OllamaException
    {
        public int Code { get; }
        public string Body { get; }
        public HttpStatus(int code, string body) : base($"Ollama returned HTTP {code}.")
        {
            Code = code;
            Body = body;
        }
    }

    public sealed class Decoding : OllamaException
    {
        public string DecodeMessage { get; }
        public Decoding(string message) : base($"Failed to decode Ollama response: {message}.")
        {
            DecodeMessage = message;
        }
    }

    public sealed class ModelNotFound : OllamaException
    {
        public string Name { get; }
        public ModelNotFound(string name) : base($"Ollama model \"{name}\" is not pulled.")
        {
            Name = name;
        }
    }

    public sealed class UnexpectedEndOfStream : OllamaException
    {
        public UnexpectedEndOfStream() : base("Ollama stream ended before completion.") { }
    }

    public sealed class Cancelled : OllamaException
    {
        public Cancelled() : base("Ollama request was cancelled.") { }
    }
}
```

- [ ] **Step 4: Implement the DTOs.**

`windows/src/AINotebook.Core/Ollama/OllamaDtos.cs` (ports `OllamaChatTypes.swift`, `OllamaEmbedTypes.swift`, `OllamaModel.swift`, `OllamaPullEvent.swift`):
```csharp
using System.Text.Json;
using System.Text.Json.Serialization;

namespace AINotebook.Core.Ollama;

/// Single shared serializer config. NO global naming policy — snake_case is
/// applied per-property via [JsonPropertyName]; nulls in options/request are
/// omitted (mirrors Swift JSONEncoder's default skip-nil behavior).
public static class OllamaJson
{
    public static readonly JsonSerializerOptions Options = new()
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        PropertyNameCaseInsensitive = false,
    };
}

[JsonConverter(typeof(JsonStringEnumConverter))]
public enum OllamaChatRole
{
    [JsonStringEnumMemberName("system")] System,
    [JsonStringEnumMemberName("user")] User,
    [JsonStringEnumMemberName("assistant")] Assistant,
}

public sealed record OllamaChatMessage(
    [property: JsonPropertyName("role")] OllamaChatRole Role,
    [property: JsonPropertyName("content")] string Content);

public sealed record OllamaChatOptions(
    [property: JsonPropertyName("temperature")] double? Temperature = null,
    [property: JsonPropertyName("num_ctx")] int? NumCtx = null);

public sealed record OllamaChatRequest(
    [property: JsonPropertyName("model")] string Model,
    [property: JsonPropertyName("messages")] IReadOnlyList<OllamaChatMessage> Messages,
    [property: JsonPropertyName("stream")] bool Stream = true,
    [property: JsonPropertyName("options")] OllamaChatOptions? Options = null);

public sealed record OllamaChatChunk(
    [property: JsonPropertyName("model")] string Model,
    [property: JsonPropertyName("created_at")] string CreatedAt,
    [property: JsonPropertyName("message")] OllamaChatMessage Message,
    [property: JsonPropertyName("done")] bool Done);

public sealed record OllamaEmbedRequest(
    [property: JsonPropertyName("model")] string Model,
    [property: JsonPropertyName("input")] IReadOnlyList<string> Input);

public sealed record OllamaEmbedResponse(
    [property: JsonPropertyName("embeddings")] double[][] Embeddings);

public sealed record OllamaModelDetails(
    [property: JsonPropertyName("format")] string? Format = null,
    [property: JsonPropertyName("family")] string? Family = null,
    [property: JsonPropertyName("parameter_size")] string? ParameterSize = null,
    [property: JsonPropertyName("quantization_level")] string? QuantizationLevel = null);

public sealed record OllamaModel(
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("modified_at")] string ModifiedAt,
    [property: JsonPropertyName("size")] long Size,
    [property: JsonPropertyName("digest")] string Digest,
    [property: JsonPropertyName("details")] OllamaModelDetails Details);

public sealed record OllamaModelList(
    [property: JsonPropertyName("models")] IReadOnlyList<OllamaModel> Models);

public sealed record OllamaPullEvent(
    [property: JsonPropertyName("status")] string Status,
    [property: JsonPropertyName("digest")] string? Digest = null,
    [property: JsonPropertyName("total")] long? Total = null,
    [property: JsonPropertyName("completed")] long? Completed = null)
{
    // Client-side derived progress; null unless total>0 and both present.
    [JsonIgnore]
    public double? FractionComplete =>
        Total is { } t && Completed is { } c && t > 0 ? (double)c / t : null;

    [JsonIgnore]
    public bool IsTerminalSuccess => Status == "success";
}
```
> Note: `JsonStringEnumMemberName` requires .NET 9. On .NET 8, replace the enum with a `[JsonConverter]` that maps the three lowercase strings, or annotate via `[EnumMember]` + a custom converter. Simplest .NET 8-safe form: drop the attributes and serialize/deserialize role as a lowercase string in `OllamaChatMessage` via a small `JsonConverter<OllamaChatRole>` that maps `system`/`user`/`assistant`. Keep the public enum shape identical either way.

- [ ] **Step 5: Implement `ChatTurn` + `IChatStreaming`/`IEmbeddingProducing` interfaces (used by later tasks).**

`windows/src/AINotebook.Core/Ollama/ChatTurn.cs` (ports `ChatTurn`/`ChatStreaming`/`EmbeddingProducing` protocol shapes; `ChatRole` is the shared model enum):
```csharp
using AINotebook.Core.Models;

namespace AINotebook.Core.Ollama;

public sealed record ChatTurn(ChatRole Role, string Content);

public interface IChatStreaming
{
    IAsyncEnumerable<string> StreamAsync(
        string model,
        IReadOnlyList<ChatTurn> messages,
        CancellationToken ct = default);
}

public interface IEmbeddingProducing
{
    Task<float[][]> EmbedAsync(string model, IReadOnlyList<string> inputs, CancellationToken ct = default);
}
```

- [ ] **Step 6: Implement `StubHttpMessageHandler`.**

`windows/tests/AINotebook.Core.Tests/Helpers/StubHttpMessageHandler.cs` (ports `StubURLProtocol`: FIFO queue, `.Json`, `.Ndjson` joining lines with `\n` + content-type `application/x-ndjson`, `.ConnectionRefused`, records last request):
```csharp
using System.Net;
using System.Text;

namespace AINotebook.Core.Tests.Helpers;

public sealed class StubHttpMessageHandler : HttpMessageHandler
{
    public sealed record Stub(int Status, string ContentType, string Body, bool ConnectionRefused = false);

    private readonly Queue<Stub> _queue = new();
    private readonly object _gate = new();

    public HttpRequestMessage? LastRequest { get; private set; }
    public string? LastRequestBody { get; private set; }
    public List<HttpRequestMessage> AllRequests { get; } = new();

    public StubHttpMessageHandler Json(string body, int status = 200)
    {
        lock (_gate) _queue.Enqueue(new Stub(status, "application/json", body));
        return this;
    }

    public StubHttpMessageHandler Ndjson(IEnumerable<string> lines, int status = 200)
    {
        // Join non-trailing-newline lines with '\n' (one JSON object per line).
        var body = string.Join("\n", lines);
        lock (_gate) _queue.Enqueue(new Stub(status, "application/x-ndjson", body));
        return this;
    }

    public StubHttpMessageHandler ConnectionRefused()
    {
        lock (_gate) _queue.Enqueue(new Stub(-1, "", "", ConnectionRefused: true));
        return this;
    }

    protected override async Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request, CancellationToken cancellationToken)
    {
        LastRequest = request;
        AllRequests.Add(request);
        LastRequestBody = request.Content is null
            ? null
            : await request.Content.ReadAsStringAsync(cancellationToken);

        Stub stub;
        lock (_gate)
        {
            if (_queue.Count == 0)
                throw new InvalidOperationException("StubHttpMessageHandler: no queued response.");
            stub = _queue.Dequeue();
        }

        if (stub.ConnectionRefused)
        {
            // Mirror URLError(.cannotConnectToHost): a transport-level failure.
            throw new HttpRequestException("Connection refused (stub).");
        }

        var resp = new HttpResponseMessage((HttpStatusCode)stub.Status)
        {
            Content = new StringContent(stub.Body, Encoding.UTF8),
        };
        resp.Content.Headers.Remove("Content-Type");
        resp.Content.Headers.TryAddWithoutValidation("Content-Type", stub.ContentType);
        return resp;
    }
}
```

- [ ] **Step 7: Run the tests — Expected: PASS.**
```
dotnet test windows/tests/AINotebook.Core.Tests --filter "FullyQualifiedName~Ollama.OllamaWireTypesTests|FullyQualifiedName~Ollama.OllamaPullEventTests|FullyQualifiedName~Ollama.OllamaModelTests"
```
Expected: PASS (10 tests).

- [ ] **Step 8: Commit.**
```
git add windows/src/AINotebook.Core/Ollama/OllamaDtos.cs windows/src/AINotebook.Core/Ollama/OllamaException.cs windows/src/AINotebook.Core/Ollama/ChatTurn.cs windows/tests/AINotebook.Core.Tests/Helpers/StubHttpMessageHandler.cs windows/tests/AINotebook.Core.Tests/Ollama/OllamaWireTypesTests.cs windows/tests/AINotebook.Core.Tests/Ollama/OllamaPullEventTests.cs windows/tests/AINotebook.Core.Tests/Ollama/OllamaModelTests.cs
git commit -m "feat(core): Ollama wire DTOs + StubHttpMessageHandler test helper

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 20: `OllamaClient`

Ports `OllamaClient.swift` 1:1. Base URL `http://127.0.0.1:11434` (IPv4 loopback, not `localhost`). Endpoints: `GET /api/tags`, `POST /api/pull`, `POST /api/embed`, `POST /api/chat`, `DELETE /api/delete`. NDJSON streaming reads line-by-line via `StreamReader.ReadLineAsync`, skips blank lines, deserializes one object per line, stops `chat` on `done==true` and `pull` on `status=="success"`. Non-2xx on a streaming endpoint captures up to 10000 bytes of the body into `HttpStatus(code, body)`. A decode failure aborts the whole stream with `Decoding`. `TaskCanceledException`/timeout → `Timeout`, all other transport failures → `NotReachable`. `DeleteModel` bypasses the helper and maps a missing response to `HttpStatus(0, "")`.

**Files:**
- Create: `windows/src/AINotebook.Core/Ollama/OllamaClient.cs`
- Test: `windows/tests/AINotebook.Core.Tests/Ollama/OllamaClientTests.cs`

- [ ] **Step 1: Write failing client tests.**

`windows/tests/AINotebook.Core.Tests/Ollama/OllamaClientTests.cs`:
```csharp
using System.Net.Http;
using AINotebook.Core.Ollama;
using AINotebook.Core.Tests.Helpers;
using Xunit;

namespace AINotebook.Core.Tests.Ollama;

public class OllamaClientTests
{
    private static OllamaClient Make(StubHttpMessageHandler stub) =>
        new(new HttpClient(stub) { BaseAddress = new Uri("http://127.0.0.1:11434") });

    // OllamaClientDetectAndListTests.testDetectTrueOn200
    [Fact]
    public async Task DetectTrueOn200()
    {
        var client = Make(new StubHttpMessageHandler().Json("""{"models":[]}""", 200));
        Assert.True(await client.DetectAsync());
    }

    // OllamaClientDetectAndListTests.testDetectFalseOnConnectionRefused
    [Fact]
    public async Task DetectFalseOnConnectionRefused()
    {
        var client = Make(new StubHttpMessageHandler().ConnectionRefused());
        Assert.False(await client.DetectAsync());
    }

    // OllamaClientDetectAndListTests.testListModelsReturnsParsedList
    [Fact]
    public async Task ListModelsReturnsParsedList()
    {
        var stub = new StubHttpMessageHandler().Json(
            """{"models":[{"name":"llama3.2:3b","modified_at":"x","size":1,"digest":"d","details":{"format":"gguf","family":"llama","parameter_size":"3B","quantization_level":"Q4"}}]}""");
        var models = await Make(stub).ListModelsAsync();
        Assert.Single(models);
        Assert.Equal("llama3.2:3b", models[0].Name);
        Assert.Equal("3B", models[0].Details.ParameterSize);
    }

    // OllamaClientDetectAndListTests.testListModelsThrowsOnHttpError
    [Fact]
    public async Task ListModelsThrowsOnHttp500()
    {
        var stub = new StubHttpMessageHandler().Json("oops", 500);
        var ex = await Assert.ThrowsAsync<OllamaException.HttpStatus>(() => Make(stub).ListModelsAsync());
        Assert.Equal(500, ex.Code);
    }

    // OllamaClientEmbedTests.testEmbedReturnsVectors
    [Fact]
    public async Task EmbedReturnsVectors()
    {
        var stub = new StubHttpMessageHandler().Json("""{"embeddings":[[0.1,0.2],[0.3,0.4]]}""");
        var vectors = await Make(stub).EmbedAsync("nomic-embed-text", new[] { "a", "b" });
        Assert.Equal(new[] { 0.1, 0.2 }, vectors[0]);
        Assert.Equal(new[] { 0.3, 0.4 }, vectors[1]);
    }

    // OllamaClientEmbedTests.testEmbedThrowsOnHttp404
    [Fact]
    public async Task EmbedThrowsOnHttp404()
    {
        var stub = new StubHttpMessageHandler().Json("nope", 404);
        var ex = await Assert.ThrowsAsync<OllamaException.HttpStatus>(
            () => Make(stub).EmbedAsync("m", new[] { "a" }));
        Assert.Equal(404, ex.Code);
    }

    // OllamaClientChatTests.testChatStreamsChunksUntilDone
    [Fact]
    public async Task ChatStreamsChunksUntilDone()
    {
        var stub = new StubHttpMessageHandler().Ndjson(new[]
        {
            """{"model":"llama3.2:3b","created_at":"x","message":{"role":"assistant","content":"He"},"done":false}""",
            """{"model":"llama3.2:3b","created_at":"x","message":{"role":"assistant","content":"llo"},"done":false}""",
            """{"model":"llama3.2:3b","created_at":"x","message":{"role":"assistant","content":""},"done":true}""",
        });
        var joined = "";
        await foreach (var chunk in Make(stub).ChatAsync("llama3.2:3b",
            new[] { new OllamaChatMessage(OllamaChatRole.User, "hi") }))
        {
            joined += chunk.Message.Content;
        }
        Assert.Equal("Hello", joined);
    }

    // OllamaClientPullTests.testPullEmitsEventsThenCompletes
    [Fact]
    public async Task PullEmitsEventsThenCompletes()
    {
        var stub = new StubHttpMessageHandler().Ndjson(new[]
        {
            """{"status":"pulling manifest"}""",
            """{"status":"downloading","total":1000,"completed":500}""",
            """{"status":"downloading","total":1000,"completed":1000}""",
            """{"status":"success"}""",
        });
        var events = new List<OllamaPullEvent>();
        await foreach (var ev in Make(stub).PullModelAsync("llama3.2:3b"))
            events.Add(ev);
        Assert.Equal(4, events.Count);
        Assert.Equal("pulling manifest", events[0].Status);
        Assert.Equal("success", events[3].Status);
        Assert.True(events[3].IsTerminalSuccess);
    }

    // OllamaClientPullTests.testPullThrowsOnHttp500
    [Fact]
    public async Task PullThrowsOnHttp500()
    {
        var stub = new StubHttpMessageHandler().Json("nope", 500);
        var ex = await Assert.ThrowsAsync<OllamaException.HttpStatus>(async () =>
        {
            await foreach (var _ in Make(stub).PullModelAsync("x")) { }
        });
        Assert.Equal(500, ex.Code);
    }

    // OllamaClientDeleteTests.testDeleteSendsCorrectRequest
    [Fact]
    public async Task DeleteSendsCorrectJsonBody()
    {
        var stub = new StubHttpMessageHandler().Json("", 200);
        await Make(stub).DeleteModelAsync("llama3.2:3b");
        Assert.Equal(HttpMethod.Delete, stub.LastRequest!.Method);
        Assert.EndsWith("/api/delete", stub.LastRequest.RequestUri!.AbsolutePath);
        Assert.Equal("""{"name":"llama3.2:3b"}""", stub.LastRequestBody);
    }

    // OllamaClientDeleteTests.testDeleteThrowsOnHttp404
    [Fact]
    public async Task DeleteThrowsOnHttp404()
    {
        var stub = new StubHttpMessageHandler().Json("not found", 404);
        var ex = await Assert.ThrowsAsync<OllamaException.HttpStatus>(
            () => Make(stub).DeleteModelAsync("ghost"));
        Assert.Equal(404, ex.Code);
    }
}
```

- [ ] **Step 2: Run — Expected: FAIL (`OllamaClient` undefined).**
```
dotnet test windows/tests/AINotebook.Core.Tests --filter "FullyQualifiedName~Ollama.OllamaClientTests"
```
Expected: FAIL.

- [ ] **Step 3: Implement `OllamaClient`.**

`windows/src/AINotebook.Core/Ollama/OllamaClient.cs` (ports `OllamaClient.swift` algorithm: status-first check then line-by-line NDJSON; helpers `SendAsync`/`EnsureSuccess` map transport errors):
```csharp
using System.Net.Http.Json;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;

namespace AINotebook.Core.Ollama;

public sealed class OllamaClient
{
    private readonly HttpClient _http;
    private static readonly JsonSerializerOptions Json = OllamaJson.Options;

    public Uri BaseUrl { get; }

    public OllamaClient(HttpClient? http = null, Uri? baseUrl = null)
    {
        BaseUrl = baseUrl ?? new Uri("http://127.0.0.1:11434");
        _http = http ?? new HttpClient();
        if (_http.BaseAddress is null) _http.BaseAddress = BaseUrl;
    }

    /// Best-effort 1.5s probe of /api/tags. true iff a 2xx response arrives.
    public async Task<bool> DetectAsync(TimeSpan? timeout = null, CancellationToken ct = default)
    {
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(timeout ?? TimeSpan.FromSeconds(1.5));
        try
        {
            using var resp = await _http.GetAsync("api/tags", HttpCompletionOption.ResponseHeadersRead, cts.Token);
            return resp.IsSuccessStatusCode;
        }
        catch
        {
            return false;
        }
    }

    public async Task<IReadOnlyList<OllamaModel>> ListModelsAsync(CancellationToken ct = default)
    {
        using var req = new HttpRequestMessage(HttpMethod.Get, "api/tags");
        using var resp = await SendAsync(req, ct);
        var body = await resp.Content.ReadAsStringAsync(ct);
        EnsureSuccess(resp, body);
        try
        {
            return JsonSerializer.Deserialize<OllamaModelList>(body, Json)!.Models;
        }
        catch (Exception e)
        {
            throw new OllamaException.Decoding(e.ToString());
        }
    }

    public async Task<double[][]> EmbedAsync(string model, IReadOnlyList<string> input, CancellationToken ct = default)
    {
        using var req = new HttpRequestMessage(HttpMethod.Post, "api/embed")
        {
            Content = JsonContent.Create(new OllamaEmbedRequest(model, input), options: Json),
        };
        using var resp = await SendAsync(req, ct);
        var body = await resp.Content.ReadAsStringAsync(ct);
        EnsureSuccess(resp, body);
        try
        {
            return JsonSerializer.Deserialize<OllamaEmbedResponse>(body, Json)!.Embeddings;
        }
        catch (Exception e)
        {
            throw new OllamaException.Decoding(e.ToString());
        }
    }

    public async Task DeleteModelAsync(string name, CancellationToken ct = default)
    {
        using var req = new HttpRequestMessage(HttpMethod.Delete, "api/delete")
        {
            // Compact, key-ordered exactly as Swift's ["name": name] encode.
            Content = new StringContent($$"""{"name":"{{name}}"}""", Encoding.UTF8, "application/json"),
        };
        HttpResponseMessage resp;
        try
        {
            resp = await _http.SendAsync(req, ct);
        }
        catch (Exception)
        {
            // deleteModel maps a missing/failed response to httpStatus(0,"").
            throw new OllamaException.HttpStatus(0, "");
        }
        using (resp)
        {
            if (!resp.IsSuccessStatusCode)
            {
                var body = await resp.Content.ReadAsStringAsync(ct);
                throw new OllamaException.HttpStatus((int)resp.StatusCode, body);
            }
        }
    }

    public IAsyncEnumerable<OllamaChatChunk> ChatAsync(
        string model,
        IReadOnlyList<OllamaChatMessage> messages,
        OllamaChatOptions? options = null,
        CancellationToken ct = default)
    {
        var payload = new OllamaChatRequest(model, messages, stream: true, options);
        return StreamNdjsonAsync<OllamaChatChunk>("api/chat", payload, c => c.Done, ct);
    }

    public IAsyncEnumerable<OllamaPullEvent> PullModelAsync(string name, CancellationToken ct = default)
    {
        var payload = new { name };
        return StreamNdjsonAsync<OllamaPullEvent>("api/pull", payload, e => e.IsTerminalSuccess, ct);
    }

    private async IAsyncEnumerable<T> StreamNdjsonAsync<T>(
        string path,
        object payload,
        Func<T, bool> isTerminal,
        [EnumeratorCancellation] CancellationToken ct)
    {
        using var req = new HttpRequestMessage(HttpMethod.Post, path)
        {
            Content = JsonContent.Create(payload, options: Json),
        };

        HttpResponseMessage resp;
        try
        {
            resp = await _http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct);
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            throw new OllamaException.Timeout();
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception)
        {
            throw new OllamaException.NotReachable();
        }

        using (resp)
        {
            if (!resp.IsSuccessStatusCode)
            {
                // Capture up to 10000 bytes of the error body.
                await using var es = await resp.Content.ReadAsStreamAsync(ct);
                var buf = new byte[10_000];
                var total = 0;
                while (total < buf.Length)
                {
                    var read = await es.ReadAsync(buf.AsMemory(total, buf.Length - total), ct);
                    if (read == 0) break;
                    total += read;
                }
                throw new OllamaException.HttpStatus(
                    (int)resp.StatusCode,
                    Encoding.UTF8.GetString(buf, 0, total));
            }

            await using var stream = await resp.Content.ReadAsStreamAsync(ct);
            using var reader = new StreamReader(stream, Encoding.UTF8);
            while (true)
            {
                string? line;
                try
                {
                    line = await reader.ReadLineAsync(ct);
                }
                catch (OperationCanceledException) when (!ct.IsCancellationRequested)
                {
                    throw new OllamaException.Timeout();
                }
                if (line is null) yield break;        // stream ended w/o terminal: finish cleanly
                if (line.Length == 0) continue;        // skip blank lines

                T value;
                try
                {
                    value = JsonSerializer.Deserialize<T>(line, Json)!;
                }
                catch (Exception e)
                {
                    throw new OllamaException.Decoding(e.ToString());
                }
                yield return value;
                if (isTerminal(value)) yield break;
            }
        }
    }

    private async Task<HttpResponseMessage> SendAsync(HttpRequestMessage req, CancellationToken ct)
    {
        try
        {
            return await _http.SendAsync(req, ct);
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            throw new OllamaException.Timeout();
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception)
        {
            throw new OllamaException.NotReachable();
        }
    }

    private static void EnsureSuccess(HttpResponseMessage resp, string body)
    {
        if (!resp.IsSuccessStatusCode)
            throw new OllamaException.HttpStatus((int)resp.StatusCode, body);
    }
}
```

- [ ] **Step 4: Run — Expected: PASS.**
```
dotnet test windows/tests/AINotebook.Core.Tests --filter "FullyQualifiedName~Ollama.OllamaClientTests"
```
Expected: PASS (11 tests).

- [ ] **Step 5: Commit.**
```
git add windows/src/AINotebook.Core/Ollama/OllamaClient.cs windows/tests/AINotebook.Core.Tests/Ollama/OllamaClientTests.cs
git commit -m "feat(core): OllamaClient (tags/pull/embed/chat/delete, NDJSON streaming)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 21: `OllamaClient` adapters for `IEmbeddingProducing` + `IChatStreaming`

Ports `OllamaClient+EmbeddingProducing.swift` and `OllamaClient+ChatStreaming.swift`. `EmbedAsync` maps `double[][]` → `float[][]` element-wise. `StreamAsync` maps `ChatTurn` → `OllamaChatMessage` (role map), yields only **non-empty** `chunk.Message.Content` deltas, and finishes when the underlying chat stream ends (the inner stream already stops on `done`). Because the underlying `OllamaClient` methods are not virtual, the adapters live in a thin wrapper that implements both interfaces.

**Files:**
- Create: `windows/src/AINotebook.Core/Ollama/OllamaAdapters.cs`
- Test: `windows/tests/AINotebook.Core.Tests/Ollama/OllamaAdapterTests.cs`

- [ ] **Step 1: Write failing adapter tests.**

`windows/tests/AINotebook.Core.Tests/Ollama/OllamaAdapterTests.cs`:
```csharp
using AINotebook.Core.Models;
using AINotebook.Core.Ollama;
using AINotebook.Core.Tests.Helpers;
using Xunit;

namespace AINotebook.Core.Tests.Ollama;

public class OllamaAdapterTests
{
    private static OllamaClient Make(StubHttpMessageHandler stub) =>
        new(new HttpClient(stub) { BaseAddress = new Uri("http://127.0.0.1:11434") });

    [Fact]
    public async Task EmbeddingAdapterMapsDoublesToFloats()
    {
        var stub = new StubHttpMessageHandler().Json("""{"embeddings":[[0.5,0.25]]}""");
        IEmbeddingProducing adapter = new OllamaEmbeddingAdapter(Make(stub));
        var vectors = await adapter.EmbedAsync("m", new[] { "a" });
        Assert.Equal(new[] { 0.5f, 0.25f }, vectors[0]);
    }

    [Fact]
    public async Task ChatAdapterYieldsOnlyNonEmptyDeltasAndMapsRoles()
    {
        var stub = new StubHttpMessageHandler().Ndjson(new[]
        {
            """{"model":"m","created_at":"x","message":{"role":"assistant","content":"alpha "},"done":false}""",
            """{"model":"m","created_at":"x","message":{"role":"assistant","content":""},"done":false}""",
            """{"model":"m","created_at":"x","message":{"role":"assistant","content":"beta"},"done":false}""",
            """{"model":"m","created_at":"x","message":{"role":"assistant","content":""},"done":true}""",
        });
        IChatStreaming adapter = new OllamaChatAdapter(Make(stub));
        var deltas = new List<string>();
        await foreach (var d in adapter.StreamAsync("m",
            new[] { new ChatTurn(ChatRole.System, "sys"), new ChatTurn(ChatRole.User, "hi") }))
        {
            deltas.Add(d);
        }
        Assert.Equal(new[] { "alpha ", "beta" }, deltas); // empty deltas dropped
    }
}
```

- [ ] **Step 2: Run — Expected: FAIL.**
```
dotnet test windows/tests/AINotebook.Core.Tests --filter "FullyQualifiedName~Ollama.OllamaAdapterTests"
```
Expected: FAIL.

- [ ] **Step 3: Implement adapters.**

`windows/src/AINotebook.Core/Ollama/OllamaAdapters.cs`:
```csharp
using System.Runtime.CompilerServices;
using AINotebook.Core.Models;

namespace AINotebook.Core.Ollama;

public sealed class OllamaEmbeddingAdapter : IEmbeddingProducing
{
    private readonly OllamaClient _client;
    public OllamaEmbeddingAdapter(OllamaClient client) => _client = client;

    public async Task<float[][]> EmbedAsync(string model, IReadOnlyList<string> inputs, CancellationToken ct = default)
    {
        var doubles = await _client.EmbedAsync(model, inputs, ct);
        var result = new float[doubles.Length][];
        for (var i = 0; i < doubles.Length; i++)
        {
            var src = doubles[i];
            var dst = new float[src.Length];
            for (var j = 0; j < src.Length; j++) dst[j] = (float)src[j];
            result[i] = dst;
        }
        return result;
    }
}

public sealed class OllamaChatAdapter : IChatStreaming
{
    private readonly OllamaClient _client;
    public OllamaChatAdapter(OllamaClient client) => _client = client;

    public async IAsyncEnumerable<string> StreamAsync(
        string model,
        IReadOnlyList<ChatTurn> messages,
        [EnumeratorCancellation] CancellationToken ct = default)
    {
        var wire = new OllamaChatMessage[messages.Count];
        for (var i = 0; i < messages.Count; i++)
            wire[i] = new OllamaChatMessage(RoleMap(messages[i].Role), messages[i].Content);

        await foreach (var chunk in _client.ChatAsync(model, wire, options: null, ct))
        {
            var delta = chunk.Message.Content;
            if (!string.IsNullOrEmpty(delta))
                yield return delta;
        }
    }

    private static OllamaChatRole RoleMap(ChatRole role) => role switch
    {
        ChatRole.System => OllamaChatRole.System,
        ChatRole.User => OllamaChatRole.User,
        ChatRole.Assistant => OllamaChatRole.Assistant,
        _ => OllamaChatRole.User,
    };
}
```

- [ ] **Step 4: Run — Expected: PASS.**
```
dotnet test windows/tests/AINotebook.Core.Tests --filter "FullyQualifiedName~Ollama.OllamaAdapterTests"
```
Expected: PASS (2 tests).

- [ ] **Step 5: Commit.**
```
git add windows/src/AINotebook.Core/Ollama/OllamaAdapters.cs windows/tests/AINotebook.Core.Tests/Ollama/OllamaAdapterTests.cs
git commit -m "feat(core): IEmbeddingProducing + IChatStreaming adapters on OllamaClient

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 22: `Embedder` + `EmbeddingWorker`

Ports `Embedder.swift` and `EmbeddingWorker.swift`. `EmbedAllPendingAsync` loops: fetch up to `batchSize` (default 16) unembedded chunks for `model` ordered by `sc.id ASC`, embed them in one call, **guard `vectors.Length == batch.Count`** else throw `EmbedderException.ResponseSizeMismatch(expected, got)`, store each `EmbeddingVector`, repeat until the batch is empty; return the total written. `EmbeddingWorker.Kick` is coalescing: a single in-flight task; concurrent kicks set a `pendingKick` flag that re-runs the drain once. `WaitUntilIdleAsync` awaits the in-flight task; `LastError`/`TotalEmbedded` are tracked.

**Files:**
- Create: `windows/src/AINotebook.Core/Rag/Embedder.cs`
- Create: `windows/src/AINotebook.Core/Rag/EmbeddingWorker.cs`
- Create: `windows/tests/AINotebook.Core.Tests/Helpers/MockEmbeddingClient.cs`
- Test: `windows/tests/AINotebook.Core.Tests/Rag/EmbedderTests.cs`

- [ ] **Step 1: Write `MockEmbeddingClient` + failing `Embedder` tests.**

`windows/tests/AINotebook.Core.Tests/Helpers/MockEmbeddingClient.cs` (records each call's inputs; returns a vector per input):
```csharp
using AINotebook.Core.Ollama;

namespace AINotebook.Core.Tests.Helpers;

public sealed class MockEmbeddingClient : IEmbeddingProducing
{
    private readonly Func<string, float[]> _vectorFor;
    public List<string[]> Calls { get; } = new();

    // Fixed vector per input string (default: deterministic 4-dim).
    public MockEmbeddingClient(Func<string, float[]>? vectorFor = null) =>
        _vectorFor = vectorFor ?? (s => new[] { 0.1f, 0.2f, 0.3f, 0.4f });

    public Task<float[][]> EmbedAsync(string model, IReadOnlyList<string> inputs, CancellationToken ct = default)
    {
        Calls.Add(inputs.ToArray());
        var result = inputs.Select(_vectorFor).ToArray();
        return Task.FromResult(result);
    }
}
```

`windows/tests/AINotebook.Core.Tests/Rag/EmbedderTests.cs`:
```csharp
using AINotebook.Core;
using AINotebook.Core.Models;
using AINotebook.Core.Rag;
using AINotebook.Core.Tests.Helpers;
using Xunit;

namespace AINotebook.Core.Tests.Rag;

public class EmbedderTests
{
    // EmbedderTests.testEmbedAllInsertsRowsForEveryChunk
    [Fact]
    public async Task EmbedAllInsertsRowsForEveryChunkInBatches()
    {
        var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("N", "");
        var src = store.CreateSource(nb.Id!.Value, SourceType.Text, "S", null, null);
        store.ReplaceChunks(src.Id!.Value, new[]
        {
            new ChunkDraft("c0", 1, null), new ChunkDraft("c1", 1, null),
            new ChunkDraft("c2", 1, null), new ChunkDraft("c3", 1, null),
            new ChunkDraft("c4", 1, null),
        });

        var client = new MockEmbeddingClient();
        var embedder = new Embedder(store, client, "m", batchSize: 2);
        var written = await embedder.EmbedAllPendingAsync();

        Assert.Equal(5, written);
        Assert.Equal(0, store.UnembeddedChunks("m", 100).Count);
        Assert.Equal(3, client.Calls.Count);
        Assert.Equal(new[] { 2, 2, 1 }, client.Calls.Select(c => c.Length).ToArray());
    }

    // EmbedderTests.testEmbedAllSkipsAlreadyEmbedded
    [Fact]
    public async Task EmbedAllSkipsAlreadyEmbedded()
    {
        var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("N", "");
        var src = store.CreateSource(nb.Id!.Value, SourceType.Text, "S", null, null);
        store.ReplaceChunks(src.Id!.Value, new[]
        {
            new ChunkDraft("a", 1, null),
            new ChunkDraft("b", 1, null),
        });
        // Pre-embed the first chunk ('a') for model 'm'.
        var first = store.UnembeddedChunks("m", 1)[0];
        store.StoreEmbedding(first.Id!.Value, "m", new EmbeddingVector(new[] { 0.1f, 0.2f, 0.3f, 0.4f }));

        var client = new MockEmbeddingClient();
        var embedder = new Embedder(store, client, "m", batchSize: 10);
        var written = await embedder.EmbedAllPendingAsync();

        Assert.Equal(1, written);
        Assert.Single(client.Calls);
        Assert.Equal(new[] { "b" }, client.Calls[0]);
    }
}
```

- [ ] **Step 2: Run — Expected: FAIL.**
```
dotnet test windows/tests/AINotebook.Core.Tests --filter "FullyQualifiedName~Rag.EmbedderTests"
```
Expected: FAIL.

- [ ] **Step 3: Implement `Embedder`.** (`EmbedderException` is NOT redefined here — it lives in Task 2/4's `Errors.cs` under namespace `AINotebook.Core`.)

`windows/src/AINotebook.Core/Rag/Embedder.cs` (ports `Embedder.swift`; uses `AINotebook.Core.EmbedderException.ResponseSizeMismatch` — the single authoritative `EmbedderException` defined in Task 2/4's `Errors.cs`, which also carries `MisalignedByteCount`):
```csharp
using AINotebook.Core;
using AINotebook.Core.Models;
using AINotebook.Core.Ollama;

namespace AINotebook.Core.Rag;

public sealed class Embedder
{
    private readonly NotebookStore _store;
    private readonly IEmbeddingProducing _client;
    public string Model { get; }
    public int BatchSize { get; }

    public Embedder(NotebookStore store, IEmbeddingProducing client, string model, int batchSize = 16)
    {
        _store = store;
        _client = client;
        Model = model;
        BatchSize = batchSize;
    }

    /// Embeds every chunk that has no row for `Model`. Returns total rows written.
    public async Task<int> EmbedAllPendingAsync(CancellationToken ct = default)
    {
        var written = 0;
        while (true)
        {
            var batch = _store.UnembeddedChunks(Model, BatchSize);
            if (batch.Count == 0) break;

            var inputs = batch.Select(c => c.Text).ToList();
            var vectors = await _client.EmbedAsync(Model, inputs, ct);
            if (vectors.Length != batch.Count)
                throw new EmbedderException.ResponseSizeMismatch(batch.Count, vectors.Length);

            for (var i = 0; i < batch.Count; i++)
            {
                _store.StoreEmbedding(batch[i].Id!.Value, Model, new EmbeddingVector(vectors[i]));
                written++;
            }
        }
        return written;
    }
}
```

- [ ] **Step 4: Implement `EmbeddingWorker`.**

`windows/src/AINotebook.Core/Rag/EmbeddingWorker.cs` (ports `EmbeddingWorker.swift`: single in-flight task + `pendingKick` re-run, guarded by a lock to mirror the actor):
```csharp
namespace AINotebook.Core.Rag;

/// Coalescing background drain runner. Kick() is idempotent: while a drain is
/// in flight, additional kicks set a "run again when this finishes" flag.
public sealed class EmbeddingWorker
{
    private readonly Embedder _embedder;
    private readonly object _gate = new();
    private Task? _inFlight;
    private bool _pendingKick;

    public Exception? LastError { get; private set; }
    public int TotalEmbedded { get; private set; }

    public EmbeddingWorker(Embedder embedder) => _embedder = embedder;

    public void Kick()
    {
        lock (_gate)
        {
            if (_inFlight is null)
                _inFlight = Task.Run(DrainAsync);
            else
                _pendingKick = true;
        }
    }

    private async Task DrainAsync()
    {
        do
        {
            lock (_gate) _pendingKick = false;
            try
            {
                var n = await _embedder.EmbedAllPendingAsync();
                lock (_gate)
                {
                    TotalEmbedded += n;
                    LastError = null;
                }
            }
            catch (Exception e)
            {
                lock (_gate) LastError = e;
            }
        }
        while (ReadPending());

        lock (_gate) _inFlight = null;
    }

    private bool ReadPending()
    {
        lock (_gate) return _pendingKick;
    }

    /// Test-only: wait until the current drain finishes (returns immediately if none).
    public async Task WaitUntilIdleAsync()
    {
        Task? task;
        lock (_gate) task = _inFlight;
        if (task is not null) await task;
    }
}
```

- [ ] **Step 5: Run — Expected: PASS.**
```
dotnet test windows/tests/AINotebook.Core.Tests --filter "FullyQualifiedName~Rag.EmbedderTests"
```
Expected: PASS (2 tests).

- [ ] **Step 6: Commit.**
```
git add windows/src/AINotebook.Core/Rag/Embedder.cs windows/src/AINotebook.Core/Rag/EmbeddingWorker.cs windows/tests/AINotebook.Core.Tests/Helpers/MockEmbeddingClient.cs windows/tests/AINotebook.Core.Tests/Rag/EmbedderTests.cs
git commit -m "feat(core): Embedder + coalescing EmbeddingWorker

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 23: `Retriever` (hybrid cosine + FTS5 BM25 with RRF)

Ports `Retriever.swift` 1:1. `SearchAsync(notebookId, query, topK=8)`: (1) embed the query and take the first vector; brute-force cosine over **all** notebook embeddings for `Model`; take `topK`. (2) FTS5 BM25 top-K via the exact SQL below — `escapeFTS` replaces `"` with `""` then wraps the whole query in double quotes (phrase search); `ORDER BY bm25(chunks_fts)` is ascending because SQLite FTS5 returns negative scores. (3) RRF fuse over **both** lists: `score[chunkId] += 1.0 / (rrfK + rank + 1)` (rank is 0-based, so rank 0 → `1/(rrfK+1)`); the vector branch sets an empty snippet first, the FTS branch overwrites with the BM25 snippet (first 240 chars). (4) Sort by fused score desc, prefix `topK`; hydrate vector-only snippets via `SELECT id,text ... WHERE id IN (...)` (first 240 chars). The `RetrievalHit.Score` is the **fused** RRF score, not cosine. `rrfK` default 60.

**Files:**
- Create: `windows/src/AINotebook.Core/Models/RetrievalHit.cs`
- Create: `windows/src/AINotebook.Core/Rag/Retriever.cs`
- Test: `windows/tests/AINotebook.Core.Tests/Rag/RetrieverTests.cs`
- (`Cosine` + `CosineTests` are defined in Task 13 — used here, not recreated.)

- [ ] **Step 1: Write the failing `Retriever` tests.** (`Cosine` + `CosineTests` already exist from Task 13 — `Retriever` just calls `Cosine.Similarity`.)

`windows/tests/AINotebook.Core.Tests/Rag/RetrieverTests.cs`:
```csharp
using AINotebook.Core;
using AINotebook.Core.Models;
using AINotebook.Core.Rag;
using AINotebook.Core.Tests.Helpers;
using Xunit;

namespace AINotebook.Core.Tests.Rag;

public class RetrieverTests
{
    private static long AddChunk(NotebookStore store, long sourceId, string text)
    {
        // append a single chunk by re-reading existing chunks then replacing.
        var existing = store.Chunks(sourceId).Select(c => new ChunkDraft(c.Text, c.TokenCount, c.PageHint)).ToList();
        existing.Add(new ChunkDraft(text, 1, null));
        store.ReplaceChunks(sourceId, existing);
        return store.Chunks(sourceId).Last().Id!.Value;
    }

    // RetrieverTests.testReturnsTopKByCosineSimilarity
    [Fact]
    public async Task ReturnsTopKByCosineSimilarity()
    {
        var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("N", "");
        var src = store.CreateSource(nb.Id!.Value, SourceType.Text, "S", null, null);
        store.ReplaceChunks(src.Id!.Value, new[]
        {
            new ChunkDraft("alpha", 1, null),
            new ChunkDraft("beta", 1, null),
            new ChunkDraft("gamma", 1, null),
        });
        var chunks = store.Chunks(src.Id!.Value);
        store.StoreEmbedding(chunks[0].Id!.Value, "m", new EmbeddingVector(new[] { 1f, 0f }));
        store.StoreEmbedding(chunks[1].Id!.Value, "m", new EmbeddingVector(new[] { 0f, 1f }));
        store.StoreEmbedding(chunks[2].Id!.Value, "m", new EmbeddingVector(new[] { -1f, 0f }));

        var client = new MockEmbeddingClient(_ => new[] { 1f, 0f }); // query vector [1,0]
        var retriever = new Retriever(store, client, "m");
        var hits = await retriever.SearchAsync(nb.Id!.Value, "anything", topK: 2);

        Assert.Equal(2, hits.Count);
        Assert.Equal(chunks[0].Id!.Value, hits[0].ChunkId);
    }

    // RetrieverTests.testFTSAloneSurfacesTextMatchWhenNoEmbedding
    [Fact]
    public async Task FtsAloneSurfacesTextMatchWhenNoEmbedding()
    {
        var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("N", "");
        var src = store.CreateSource(nb.Id!.Value, SourceType.Text, "S", null, null);
        store.ReplaceChunks(src.Id!.Value, new[]
        {
            new ChunkDraft("the quick brown fox", 1, null),
            new ChunkDraft("unrelated content", 1, null),
        });
        // No embeddings stored.
        var client = new MockEmbeddingClient(_ => new[] { 0f, 0f });
        var retriever = new Retriever(store, client, "m");
        var hits = await retriever.SearchAsync(nb.Id!.Value, "fox", topK: 5);

        var foxId = store.Chunks(src.Id!.Value)[0].Id!.Value;
        Assert.Contains(hits, h => h.ChunkId == foxId);
    }

    // RetrieverTests.testRRFRanksFusedAboveSingleSourceMatch
    [Fact]
    public async Task RrfRanksFusedAboveSingleSourceMatch()
    {
        var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("N", "");
        var src = store.CreateSource(nb.Id!.Value, SourceType.Text, "S", null, null);
        store.ReplaceChunks(src.Id!.Value, new[]
        {
            new ChunkDraft("the quick brown fox", 1, null), // A: vector + text
            new ChunkDraft("a fox in the henhouse", 1, null), // B: text only
            new ChunkDraft("unrelated text", 1, null),        // C: vector only
        });
        var chunks = store.Chunks(src.Id!.Value);
        var aId = chunks[0].Id!.Value;
        store.StoreEmbedding(aId, "m", new EmbeddingVector(new[] { 1f, 0f }));
        store.StoreEmbedding(chunks[2].Id!.Value, "m", new EmbeddingVector(new[] { 0.9f, 0.1f }));

        var client = new MockEmbeddingClient(_ => new[] { 1f, 0f });
        var retriever = new Retriever(store, client, "m");
        var hits = await retriever.SearchAsync(nb.Id!.Value, "fox", topK: 3);

        Assert.Equal(aId, hits[0].ChunkId);
    }
}
```

- [ ] **Step 2: Run — Expected: FAIL.**
```
dotnet test windows/tests/AINotebook.Core.Tests --filter "FullyQualifiedName~Rag.RetrieverTests"
```
Expected: FAIL.

- [ ] **Step 3: `Cosine` already exists (Task 13).** `windows/src/AINotebook.Core/Rag/Cosine.cs` (namespace `AINotebook.Core.Rag`) is created in Task 13 with verbatim `CosineTests`. Do NOT recreate it here — `Retriever.cs` is in the same `AINotebook.Core.Rag` namespace, so `Cosine.Similarity` resolves with no extra `using`.

- [ ] **Step 4: Implement `RetrievalHit`.**

`windows/src/AINotebook.Core/Models/RetrievalHit.cs`:
```csharp
namespace AINotebook.Core.Models;

public sealed record RetrievalHit(long ChunkId, long SourceId, float Score, string Snippet);
```

- [ ] **Step 5: Implement `Retriever`.**

`windows/src/AINotebook.Core/Rag/Retriever.cs` (ports `Retriever.swift` + its SQL helpers verbatim; uses `NotebookStore` to obtain the open `SqliteConnection`):
```csharp
using AINotebook.Core.Models;
using AINotebook.Core.Ollama;
using Microsoft.Data.Sqlite;

namespace AINotebook.Core.Rag;

public sealed class Retriever
{
    private readonly NotebookStore _store;
    private readonly IEmbeddingProducing _client;
    public string Model { get; }
    public int RrfK { get; }

    public Retriever(NotebookStore store, IEmbeddingProducing client, string model, int rrfK = 60)
    {
        _store = store;
        _client = client;
        Model = model;
        RrfK = rrfK;
    }

    public async Task<IReadOnlyList<RetrievalHit>> SearchAsync(
        long notebookId, string query, int topK = 8, CancellationToken ct = default)
    {
        // 1) Vector ranking — embed query, brute-force cosine over all embeddings.
        var queryVectors = await _client.EmbedAsync(Model, new[] { query }, ct);
        var queryVector = queryVectors.Length > 0 ? queryVectors[0] : Array.Empty<float>();

        var allEmbeddings = _store.Embeddings(notebookId, Model);
        var vectorRanked = allEmbeddings
            .Select(e => (e.ChunkId, e.SourceId, Score: Cosine.Similarity(queryVector, e.Vector.Values)))
            .OrderByDescending(x => x.Score)
            .Take(topK)
            .ToList();

        // 2) FTS ranking — BM25 top-K within the notebook.
        var ftsRanked = FtsTopK(notebookId, query, topK);

        // 3) Reciprocal Rank Fusion over BOTH lists.
        var rrfScores = new Dictionary<long, float>();
        var meta = new Dictionary<long, (long SourceId, string Snippet)>();
        for (var rank = 0; rank < vectorRanked.Count; rank++)
        {
            var hit = vectorRanked[rank];
            rrfScores[hit.ChunkId] = rrfScores.GetValueOrDefault(hit.ChunkId) + 1.0f / (RrfK + rank + 1);
            meta[hit.ChunkId] = (hit.SourceId, "");
        }
        for (var rank = 0; rank < ftsRanked.Count; rank++)
        {
            var hit = ftsRanked[rank];
            rrfScores[hit.ChunkId] = rrfScores.GetValueOrDefault(hit.ChunkId) + 1.0f / (RrfK + rank + 1);
            meta[hit.ChunkId] = (hit.SourceId, hit.Snippet);  // FTS overwrites with bm25 snippet
        }

        // 4) Hydrate snippets for chunks that only came from the vector branch.
        var missing = meta.Where(kv => kv.Value.Snippet.Length == 0).Select(kv => kv.Key).ToList();
        if (missing.Count > 0)
        {
            var snippets = Snippets(missing);
            foreach (var (id, snip) in snippets)
                meta[id] = (meta[id].SourceId, snip);
        }

        return rrfScores
            .OrderByDescending(kv => kv.Value)
            .Take(topK)
            .Where(kv => meta.ContainsKey(kv.Key))
            .Select(kv => new RetrievalHit(kv.Key, meta[kv.Key].SourceId, kv.Value, meta[kv.Key].Snippet))
            .ToList();
    }

    private List<(long ChunkId, long SourceId, string Snippet)> FtsTopK(long notebookId, string query, int k)
    {
        var conn = _store.Connection;
        using var cmd = conn.CreateCommand();
        cmd.CommandText = """
            SELECT sc.id AS chunk_id, sc.source_id AS source_id, sc.text AS text
            FROM chunks_fts f
            JOIN source_chunks sc ON sc.id = f.chunk_id
            JOIN sources s ON s.id = sc.source_id
            WHERE f.text MATCH $q AND s.notebook_id = $nb
            ORDER BY bm25(chunks_fts)
            LIMIT $k
            """;
        cmd.Parameters.AddWithValue("$q", EscapeFts(query));
        cmd.Parameters.AddWithValue("$nb", notebookId);
        cmd.Parameters.AddWithValue("$k", k);

        var rows = new List<(long, long, string)>();
        using var reader = cmd.ExecuteReader();
        while (reader.Read())
        {
            var text = reader.GetString(2);
            rows.Add((reader.GetInt64(0), reader.GetInt64(1), Prefix240(text)));
        }
        return rows;
    }

    private Dictionary<long, string> Snippets(IReadOnlyList<long> chunkIds)
    {
        var result = new Dictionary<long, string>();
        if (chunkIds.Count == 0) return result;

        var conn = _store.Connection;
        var placeholders = string.Join(",", chunkIds.Select((_, i) => "$p" + i));
        using var cmd = conn.CreateCommand();
        cmd.CommandText = $"SELECT id, text FROM source_chunks WHERE id IN ({placeholders})";
        for (var i = 0; i < chunkIds.Count; i++)
            cmd.Parameters.AddWithValue("$p" + i, chunkIds[i]);

        using var reader = cmd.ExecuteReader();
        while (reader.Read())
            result[reader.GetInt64(0)] = Prefix240(reader.GetString(1));
        return result;
    }

    private static string Prefix240(string text) => text.Length <= 240 ? text : text[..240];

    /// Wrap whole query as an FTS5 phrase: replace " with "" then surround in quotes.
    private static string EscapeFts(string raw) => "\"" + raw.Replace("\"", "\"\"") + "\"";
}
```
> Note: `NotebookStore` exposes its open `SqliteConnection` via an `internal SqliteConnection Connection { get; }` property (defined in Task 6; `Retriever` is in the same assembly `AINotebook.Core`, so `internal` access suffices — no `public` is needed). Methods `Embeddings(long notebookId, string model)` (returns `IReadOnlyList<StoredEmbedding>`) and `Chunks(long sourceId)` are likewise on the store.

- [ ] **Step 6: Run — Expected: PASS.**
```
dotnet test windows/tests/AINotebook.Core.Tests --filter "FullyQualifiedName~Rag.RetrieverTests"
```
Expected: PASS (3 tests).

- [ ] **Step 7: Commit.**
```
git add windows/src/AINotebook.Core/Models/RetrievalHit.cs windows/src/AINotebook.Core/Rag/Retriever.cs windows/tests/AINotebook.Core.Tests/Rag/RetrieverTests.cs
git commit -m "feat(core): Retriever — hybrid cosine + FTS5 BM25 with RRF fusion

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 24: `CitationParser` + `SystemPrompt`

Ports `CitationParser.swift` and `SystemPrompt.swift` 1:1. `CitationParser.Markers`: regex `\[(\d+)\]`, returns ints in match order **with duplicates**, only positive integers. `SystemPrompt.Compose`: the header literal is reproduced **character-for-character including the em-dash (U+2014)** in the optional note section; the CONTEXT section is `"CONTEXT:\n(none)"` when there are no hits, else `"CONTEXT:\n"` + numbered `"[i+1] snippet"` blocks joined by `\n`; the optional `"CURRENTLY OPEN NOTE (additional context — user may be asking about this):\n"` + note section appears only when the note is non-empty after trimming; sections are joined by `\n\n`.

**Files:**
- Create: `windows/src/AINotebook.Core/Rag/CitationParser.cs`
- Create: `windows/src/AINotebook.Core/Rag/SystemPrompt.cs`
- Test: `windows/tests/AINotebook.Core.Tests/Rag/CitationParserTests.cs`
- Test: `windows/tests/AINotebook.Core.Tests/Rag/SystemPromptTests.cs`

- [ ] **Step 1: Write failing tests.**

`windows/tests/AINotebook.Core.Tests/Rag/CitationParserTests.cs`:
```csharp
using AINotebook.Core.Rag;
using Xunit;

namespace AINotebook.Core.Tests.Rag;

public class CitationParserTests
{
    [Fact] // testFindsSingleCitation
    public void FindsSingleCitation() =>
        Assert.Equal(new[] { 1 }, CitationParser.Markers("The sky is blue [1]."));

    [Fact] // testFindsMultipleCitationsInOrder (order + dupes preserved)
    public void FindsMultipleCitationsInOrderWithDupes() =>
        Assert.Equal(new[] { 2, 5, 2 }, CitationParser.Markers("First [2]. Second [5]. Third [2]."));

    [Fact] // testIgnoresMalformedMarkers
    public void IgnoresMalformedMarkers() =>
        Assert.Equal(new[] { 1 }, CitationParser.Markers("[abc] [1.2] [-3] [1]"));

    [Fact] // testHandlesAdjacentMarkers
    public void HandlesAdjacentMarkers() =>
        Assert.Equal(new[] { 1, 3 }, CitationParser.Markers("Both true [1][3]."));

    [Fact] // testEmptyOrNoMatchReturnsEmpty
    public void EmptyOrNoMatchReturnsEmpty()
    {
        Assert.Empty(CitationParser.Markers(""));
        Assert.Empty(CitationParser.Markers("no markers here"));
    }
}
```

`windows/tests/AINotebook.Core.Tests/Rag/SystemPromptTests.cs`:
```csharp
using AINotebook.Core.Models;
using AINotebook.Core.Rag;
using Xunit;

namespace AINotebook.Core.Tests.Rag;

public class SystemPromptTests
{
    // SystemPromptTests.testRendersHitsAsNumberedBlocks
    [Fact]
    public void RendersHitsAsNumberedBlocks()
    {
        var hits = new[]
        {
            new RetrievalHit(1, 1, 0.5f, "alpha facts"),
            new RetrievalHit(2, 1, 0.4f, "beta facts"),
        };
        var prompt = SystemPrompt.Compose(hits);
        Assert.Contains("[1] alpha facts", prompt);
        Assert.Contains("[2] beta facts", prompt);
    }

    // SystemPromptTests.testIncludesCitationInstruction
    [Fact]
    public void IncludesCitationInstruction()
    {
        var prompt = SystemPrompt.Compose(Array.Empty<RetrievalHit>());
        Assert.Contains("cite", prompt.ToLowerInvariant());
        Assert.Contains("[N]", prompt);
    }

    // SystemPromptTests.testNoHitsStillProducesValidPrompt
    [Fact]
    public void NoHitsStillProducesNonEmptyPrompt() =>
        Assert.False(string.IsNullOrEmpty(SystemPrompt.Compose(Array.Empty<RetrievalHit>())));

    // Includes note section when provided (ChatEngineCurrentNoteContextTests companion).
    [Fact]
    public void IncludesNoteSectionWhenProvided()
    {
        var prompt = SystemPrompt.Compose(Array.Empty<RetrievalHit>(), "flour 500g");
        Assert.Contains("CURRENTLY OPEN NOTE", prompt);
        Assert.Contains("flour 500g", prompt);
    }

    [Fact]
    public void OmitsNoteSectionWhenNullOrBlank()
    {
        Assert.DoesNotContain("CURRENTLY OPEN NOTE", SystemPrompt.Compose(Array.Empty<RetrievalHit>(), null));
        Assert.DoesNotContain("CURRENTLY OPEN NOTE", SystemPrompt.Compose(Array.Empty<RetrievalHit>(), "   "));
    }
}
```

- [ ] **Step 2: Run — Expected: FAIL.**
```
dotnet test windows/tests/AINotebook.Core.Tests --filter "FullyQualifiedName~Rag.CitationParserTests|FullyQualifiedName~Rag.SystemPromptTests"
```
Expected: FAIL.

- [ ] **Step 3: Implement `CitationParser`.**

`windows/src/AINotebook.Core/Rag/CitationParser.cs`:
```csharp
using System.Text.RegularExpressions;

namespace AINotebook.Core.Rag;

public static class CitationParser
{
    private static readonly Regex Pattern = new(@"\[(\d+)\]", RegexOptions.Compiled);

    /// Returns 1-based citation numbers in match order, WITH duplicates,
    /// keeping only positive integers.
    public static List<int> Markers(string text)
    {
        var results = new List<int>();
        foreach (Match m in Pattern.Matches(text))
        {
            if (int.TryParse(m.Groups[1].Value, out var n) && n > 0)
                results.Add(n);
        }
        return results;
    }
}
```

- [ ] **Step 4: Implement `SystemPrompt`.**

`windows/src/AINotebook.Core/Rag/SystemPrompt.cs` (header text is verbatim from `SystemPrompt.swift`; the note-section header contains the em-dash U+2014):
```csharp
using System.Text;
using AINotebook.Core.Models;

namespace AINotebook.Core.Rag;

public static class SystemPrompt
{
    // Verbatim from SystemPrompt.swift (line-broken identically).
    private const string Header =
        "You are a helpful assistant answering questions about the user's notebook.\n" +
        "Use ONLY the provided CONTEXT to answer. If the answer isn't in the\n" +
        "context, say so plainly. When you use a fact from a context block,\n" +
        "cite it inline as [N] where N is the block number. Multiple citations\n" +
        "may appear in a single sentence: [1][3].";

    public static string Compose(IReadOnlyList<RetrievalHit> hits, string? currentNoteContent = null)
    {
        var sections = new List<string> { Header };

        if (hits.Count == 0)
        {
            sections.Add("CONTEXT:\n(none)");
        }
        else
        {
            var blocks = string.Join("\n",
                hits.Select((hit, i) => $"[{i + 1}] {hit.Snippet}"));
            sections.Add("CONTEXT:\n" + blocks);
        }

        if (currentNoteContent is { } note &&
            !string.IsNullOrEmpty(note.Trim()))
        {
            // The "—" below is an em-dash, U+2014.
            sections.Add(
                "CURRENTLY OPEN NOTE (additional context — user may be asking about this):\n" + note);
        }

        return string.Join("\n\n", sections);
    }
}
```

- [ ] **Step 5: Run — Expected: PASS.**
```
dotnet test windows/tests/AINotebook.Core.Tests --filter "FullyQualifiedName~Rag.CitationParserTests|FullyQualifiedName~Rag.SystemPromptTests"
```
Expected: PASS (10 tests).

- [ ] **Step 6: Commit.**
```
git add windows/src/AINotebook.Core/Rag/CitationParser.cs windows/src/AINotebook.Core/Rag/SystemPrompt.cs windows/tests/AINotebook.Core.Tests/Rag/CitationParserTests.cs windows/tests/AINotebook.Core.Tests/Rag/SystemPromptTests.cs
git commit -m "feat(core): CitationParser + SystemPrompt (verbatim header, RRF context blocks)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 25: `ChatEngine` + `TransformationEngine` + `NoteIndexer`

Ports `ChatEngine.swift`, `TransformationEngine.swift`, `NoteIndexer.swift` 1:1.

**ChatEngine.SendAsync**: persist the user message; `hits = retriever.SearchAsync(notebookId, userText, topK)`; `system = SystemPrompt.Compose(hits, currentNoteContent)`; build `turns = [system] + full history`; stream tokens **with retry** (`retryAttempts=2`, backoff `retryBackoffMillis * 2^(attempt-1)` ms — total tries = `retryAttempts + 1`) accumulating into `assembled` and invoking `onToken` per delta; parse markers with `CitationParser`, **dedupe preserving first-seen order**, keep only markers in `1..hits.Count`, map marker `m` → `hits[m-1]` into a `Citation`; persist the assistant message with citations; return it.

**TransformationEngine.RunAsync**: load the transformation (else `TransformationNotFound`), the source (else `SourceNotFound`), the chunks (else `NoChunks`); `sourceText = chunks.Text` joined with `"\n\n"`; `rendered = PromptTemplate.Replace("{{source_text}}", sourceText)`; `turns = [user rendered]` (NO system turn); stream + assemble; `title = $"{Name} — {source.Title}"` (em-dash U+2014); create a note with `Origin.Transformation`, `OriginRef = transformation.Id`; record the run. `RunNotebookScopeAsync` concatenates all sources, `sourceId = null`, title `"{Name} — {n} sources"`. `RunOnAllSourcesAsync` loops, calling `onProgress(i+1, total)`, producing one note per source.

**NoteIndexer.IndexAsync**: ensure a shadow `Source` of type `Note` exists for the note (creating + linking via `AutoSourceId` if absent, syncing the title if it changed); chunk the note body (empty body → no chunks); `ReplaceChunks` + set status `Ready`; fire the `onChunksWritten` callback.

**Files:**
- Create: `windows/src/AINotebook.Core/Rag/ChatEngine.cs`
- Create: `windows/src/AINotebook.Core/Rag/TransformationEngine.cs`
- Create: `windows/src/AINotebook.Core/Rag/NoteIndexer.cs`
- Create: `windows/tests/AINotebook.Core.Tests/Helpers/ChatStubs.cs`
- Test: `windows/tests/AINotebook.Core.Tests/Rag/ChatEngineTests.cs`
- Test: `windows/tests/AINotebook.Core.Tests/Rag/TransformationEngineTests.cs`
- Test: `windows/tests/AINotebook.Core.Tests/Rag/NoteIndexerTests.cs`

- [ ] **Step 1: Write chat stubs + failing engine tests.**

`windows/tests/AINotebook.Core.Tests/Helpers/ChatStubs.cs` (`MockChatClient` replays fixed tokens recording captured turns; `StaggeredChat` yields each token with a small async hop; `FlakyChat` fails N times then succeeds):
```csharp
using System.Runtime.CompilerServices;
using AINotebook.Core.Models;
using AINotebook.Core.Ollama;

namespace AINotebook.Core.Tests.Helpers;

public sealed class MockChatClient : IChatStreaming
{
    private readonly string[] _tokens;
    public List<IReadOnlyList<ChatTurn>> CapturedMessages { get; } = new();
    public int Calls => CapturedMessages.Count;

    public MockChatClient(params string[] tokens) => _tokens = tokens;

    public async IAsyncEnumerable<string> StreamAsync(
        string model, IReadOnlyList<ChatTurn> messages,
        [EnumeratorCancellation] CancellationToken ct = default)
    {
        CapturedMessages.Add(messages);
        foreach (var t in _tokens)
        {
            await Task.Yield();
            yield return t;
        }
    }
}

public sealed class StaggeredChat : IChatStreaming
{
    private readonly string[] _tokens;
    public StaggeredChat(params string[] tokens) => _tokens = tokens;

    public async IAsyncEnumerable<string> StreamAsync(
        string model, IReadOnlyList<ChatTurn> messages,
        [EnumeratorCancellation] CancellationToken ct = default)
    {
        foreach (var t in _tokens)
        {
            await Task.Delay(1, ct);
            yield return t;
        }
    }
}

public sealed class FlakyChat : IChatStreaming
{
    private readonly int _failTimes;
    private readonly string _finalToken;
    public int Attempts { get; private set; }

    public FlakyChat(int failTimes, string finalToken = "ok")
    {
        _failTimes = failTimes;
        _finalToken = finalToken;
    }

    public async IAsyncEnumerable<string> StreamAsync(
        string model, IReadOnlyList<ChatTurn> messages,
        [EnumeratorCancellation] CancellationToken ct = default)
    {
        Attempts++;
        if (Attempts <= _failTimes)
        {
            await Task.Yield();
            throw new OllamaException.Timeout();
        }
        await Task.Yield();
        yield return _finalToken;
    }
}
```

`windows/tests/AINotebook.Core.Tests/Rag/ChatEngineTests.cs`:
```csharp
using AINotebook.Core;
using AINotebook.Core.Models;
using AINotebook.Core.Rag;
using AINotebook.Core.Tests.Helpers;
using Xunit;

namespace AINotebook.Core.Tests.Rag;

public class ChatEngineTests
{
    private static (NotebookStore store, long nbId, long sessionId, long chunkId) Setup()
    {
        var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("N", "");
        var src = store.CreateSource(nb.Id!.Value, SourceType.Text, "S", null, null);
        store.ReplaceChunks(src.Id!.Value, new[] { new ChunkDraft("the sky is blue", 1, null) });
        var chunkId = store.Chunks(src.Id!.Value)[0].Id!.Value;
        store.StoreEmbedding(chunkId, "emb", new EmbeddingVector(new[] { 1f, 0f }));
        var session = store.CreateChatSession(nb.Id!.Value, "T");
        return (store, nb.Id!.Value, session.Id!.Value, chunkId);
    }

    // ChatEngineTests.testEndToEndStreamsTokensThenPersistsMessages
    [Fact]
    public async Task EndToEndStreamsTokensThenPersistsMessages()
    {
        var (store, nbId, sessionId, chunkId) = Setup();
        var emb = new MockEmbeddingClient(_ => new[] { 1f, 0f });
        var retriever = new Retriever(store, emb, "emb");
        var chat = new MockChatClient("The sky ", "is blue ", "[1].");
        var engine = new ChatEngine(store, retriever, chat, "chatmodel");

        var streamed = new List<string>();
        var final = await engine.SendAsync(sessionId, nbId, "what color is the sky?",
            onToken: t => streamed.Add(t));

        Assert.Equal(new[] { "The sky ", "is blue ", "[1]." }, streamed);
        Assert.Equal("The sky is blue [1].", final.Content);
        Assert.Equal(chunkId, final.Citations[0].ChunkId);

        var persisted = store.Messages(sessionId);
        Assert.Equal(2, persisted.Count);
        Assert.Equal(ChatRole.User, persisted[0].Role);
        Assert.Equal(ChatRole.Assistant, persisted[1].Role);

        // first turn system, last turn user with the userText
        var turns = chat.CapturedMessages[0];
        Assert.Single(chat.CapturedMessages);
        Assert.Equal(ChatRole.System, turns[0].Role);
        Assert.Equal(ChatRole.User, turns[^1].Role);
        Assert.Equal("what color is the sky?", turns[^1].Content);
    }

    // ChatEngineRetryTests.testRetriesOnceOnTimeoutThenSucceeds
    [Fact]
    public async Task RetriesOnceOnTimeoutThenSucceeds()
    {
        var (store, nbId, sessionId, _) = Setup();
        var emb = new MockEmbeddingClient(_ => new[] { 1f, 0f });
        var retriever = new Retriever(store, emb, "emb");
        var chat = new FlakyChat(failTimes: 1, finalToken: "ok");
        var engine = new ChatEngine(store, retriever, chat, "m",
            retryAttempts: 1, retryBackoffMillis: 1);

        var msg = await engine.SendAsync(sessionId, nbId, "q", onToken: _ => { });
        Assert.Equal("ok", msg.Content);
        Assert.Equal(2, chat.Attempts);
    }

    // ChatEngineRetryTests.testGivesUpAfterMaxAttempts
    [Fact]
    public async Task GivesUpAfterMaxAttempts()
    {
        var (store, nbId, sessionId, _) = Setup();
        var emb = new MockEmbeddingClient(_ => new[] { 1f, 0f });
        var retriever = new Retriever(store, emb, "emb");
        var chat = new FlakyChat(failTimes: 99);
        var engine = new ChatEngine(store, retriever, chat, "m",
            retryAttempts: 2, retryBackoffMillis: 1);

        await Assert.ThrowsAnyAsync<Exception>(() => engine.SendAsync(sessionId, nbId, "q", onToken: _ => { }));
        Assert.Equal(3, chat.Attempts); // retryAttempts + 1 total tries
    }

    // ChatEngineCurrentNoteContextTests.testCurrentNoteContextAppearsInSystemPrompt
    [Fact]
    public async Task CurrentNoteContextAppearsInSystemPrompt()
    {
        var (store, nbId, sessionId, _) = Setup();
        var emb = new MockEmbeddingClient(_ => new[] { 1f, 0f });
        var retriever = new Retriever(store, emb, "emb");
        var chat = new MockChatClient("ok");
        var engine = new ChatEngine(store, retriever, chat, "m");

        await engine.SendAsync(sessionId, nbId, "q", currentNoteContent: "flour 500g", onToken: _ => { });
        var systemTurn = chat.CapturedMessages[0][0];
        Assert.Contains("CURRENTLY OPEN NOTE", systemTurn.Content);
        Assert.Contains("flour 500g", systemTurn.Content);
    }

    // ChatEngineCurrentNoteContextTests.testNilCurrentNoteContextLeavesPromptUnchanged
    [Fact]
    public async Task NullCurrentNoteContextLeavesPromptUnchanged()
    {
        var (store, nbId, sessionId, _) = Setup();
        var emb = new MockEmbeddingClient(_ => new[] { 1f, 0f });
        var retriever = new Retriever(store, emb, "emb");
        var chat = new MockChatClient("ok");
        var engine = new ChatEngine(store, retriever, chat, "m");

        await engine.SendAsync(sessionId, nbId, "q", onToken: _ => { });
        Assert.DoesNotContain("CURRENTLY OPEN NOTE", chat.CapturedMessages[0][0].Content);
    }
}
```

`windows/tests/AINotebook.Core.Tests/Rag/TransformationEngineTests.cs`:
```csharp
using AINotebook.Core;
using AINotebook.Core.Models;
using AINotebook.Core.Rag;
using AINotebook.Core.Tests.Helpers;
using Xunit;

namespace AINotebook.Core.Tests.Rag;

public class TransformationEngineTests
{
    private static long MakeTransformation(NotebookStore store, string name, string template)
    {
        var t = store.CreateTransformation(name, template, TransformationScope.Source, isBuiltin: false);
        return t.Id!.Value;
    }

    // TransformationEngineTests.testRunsTemplateOverSourceAndSavesAsNote
    [Fact]
    public async Task RunsTemplateOverSourceAndSavesAsNote()
    {
        var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("N", "");
        var src = store.CreateSource(nb.Id!.Value, SourceType.Text, "Doc", null, null);
        store.ReplaceChunks(src.Id!.Value, new[]
        {
            new ChunkDraft("Alpha", 1, null),
            new ChunkDraft("Beta", 1, null),
        });
        var tId = MakeTransformation(store, "Summary", "TEMPLATE:\n{{source_text}}");

        var chat = new MockChatClient("- Alpha\n", "- Beta\n");
        var engine = new TransformationEngine(store, chat, "m");
        var note = await engine.RunAsync(tId, src.Id!.Value);

        Assert.Equal(NoteOrigin.Transformation, note.Origin);
        Assert.Equal("- Alpha\n- Beta\n", note.BodyMd);
        Assert.Contains("Sum", note.Title);

        var runs = store.TransformationRuns();
        Assert.Single(runs);
        Assert.Equal(src.Id!.Value, runs[0].SourceId);
        Assert.Equal(note.Id, runs[0].ResultNoteId);

        var userTurn = chat.CapturedMessages[0][0];
        Assert.Equal(ChatRole.User, userTurn.Role);
        Assert.Contains("Alpha", userTurn.Content);
        Assert.Contains("Beta", userTurn.Content);
        Assert.Contains("TEMPLATE:", userTurn.Content);
    }

    // TransformationEngineTests.testRejectsMissingSource
    [Fact]
    public async Task RejectsMissingSource()
    {
        var store = new NotebookStore(StorePath.InMemory);
        store.CreateNotebook("N", "");
        var tId = MakeTransformation(store, "Summary", "{{source_text}}");
        var engine = new TransformationEngine(store, new MockChatClient("x"), "m");

        await Assert.ThrowsAsync<TransformationException.SourceNotFound>(
            () => engine.RunAsync(tId, 999));
    }

    // TransformationEngineStreamTests.testStreamsTokensWhileRunning
    [Fact]
    public async Task StreamsTokensWhileRunning()
    {
        var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("N", "");
        var src = store.CreateSource(nb.Id!.Value, SourceType.Text, "Doc", null, null);
        store.ReplaceChunks(src.Id!.Value, new[] { new ChunkDraft("body", 1, null) });
        var tId = MakeTransformation(store, "Summary", "{{source_text}}");

        var chat = new StaggeredChat("alpha ", "beta ", "gamma");
        var engine = new TransformationEngine(store, chat, "m");

        var received = new List<string>();
        var note = await engine.RunAsync(tId, src.Id!.Value, onToken: t => received.Add(t));

        Assert.Equal(new[] { "alpha ", "beta ", "gamma" }, received);
        Assert.Equal("alpha beta gamma", note.BodyMd);
    }

    // TransformationNotebookScopeTests.testRunNotebookScopeConcatenatesAllSources
    [Fact]
    public async Task RunNotebookScopeConcatenatesAllSources()
    {
        var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("N", "");
        var s1 = store.CreateSource(nb.Id!.Value, SourceType.Text, "S1", null, null);
        store.ReplaceChunks(s1.Id!.Value, new[] { new ChunkDraft("A1", 1, null) });
        var s2 = store.CreateSource(nb.Id!.Value, SourceType.Text, "S2", null, null);
        store.ReplaceChunks(s2.Id!.Value, new[] { new ChunkDraft("B1", 1, null) });
        var tId = MakeTransformation(store, "Summary", "{{source_text}}");

        var chat = new MockChatClient("Summary of all");
        var engine = new TransformationEngine(store, chat, "m");
        var note = await engine.RunNotebookScopeAsync(tId, nb.Id!.Value);

        Assert.Equal("Summary of all", note.BodyMd);
        var userTurn = chat.CapturedMessages[0][0];
        Assert.Contains("A1", userTurn.Content);
        Assert.Contains("B1", userTurn.Content);
    }

    // TransformationBatchTests.testRunsTemplateOnEverySourceProducingOneNoteEach
    [Fact]
    public async Task RunsTemplateOnEverySourceProducingOneNoteEach()
    {
        var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("N", "");
        for (var i = 0; i < 3; i++)
        {
            var s = store.CreateSource(nb.Id!.Value, SourceType.Text, $"S{i}", null, null);
            store.ReplaceChunks(s.Id!.Value, new[] { new ChunkDraft($"text{i}", 1, null) });
        }
        var tId = MakeTransformation(store, "Summary", "{{source_text}}");

        var chat = new MockChatClient("out");
        var engine = new TransformationEngine(store, chat, "m");
        var notes = await engine.RunOnAllSourcesAsync(tId, nb.Id!.Value);

        Assert.Equal(3, notes.Count);
        Assert.Equal(3, chat.Calls);
        Assert.All(notes, n => Assert.Equal(NoteOrigin.Transformation, n.Origin));
    }

    // TransformationBatchTests.testEmptyNotebookReturnsEmptyArray
    [Fact]
    public async Task EmptyNotebookReturnsEmptyArray()
    {
        var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("N", "");
        var tId = MakeTransformation(store, "Summary", "{{source_text}}");
        var engine = new TransformationEngine(store, new MockChatClient("x"), "m");

        var notes = await engine.RunOnAllSourcesAsync(tId, nb.Id!.Value);
        Assert.Empty(notes);
    }
}
```

`windows/tests/AINotebook.Core.Tests/Rag/NoteIndexerTests.cs`:
```csharp
using AINotebook.Core;
using AINotebook.Core.Models;
using AINotebook.Core.Rag;
using Xunit;

namespace AINotebook.Core.Tests.Rag;

public class NoteIndexerTests
{
    // NoteIndexerTests.testIndexCreatesShadowSourceAndChunks
    [Fact]
    public async Task IndexCreatesShadowSourceAndChunks()
    {
        var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("N", "");
        var note = store.CreateNote(nb.Id!.Value, "Recipe", "Mix flour and water.", NoteOrigin.Manual, null);

        var indexer = new NoteIndexer(store);
        await indexer.IndexAsync(note.Id!.Value);

        var refreshed = store.Note(note.Id!.Value)!;
        Assert.NotNull(refreshed.AutoSourceId);
        var shadow = store.Source(refreshed.AutoSourceId!.Value)!;
        Assert.Equal(SourceType.Note, shadow.Type);
        Assert.Equal("Recipe", shadow.Title);
        Assert.Equal(SourceStatus.Ready, shadow.Status);

        var chunks = store.Chunks(shadow.Id!.Value);
        Assert.NotEmpty(chunks);
        Assert.Contains(chunks, c => c.Text.Contains("flour"));
    }

    // NoteIndexerTests.testReindexReplacesChunks
    [Fact]
    public async Task ReindexReplacesChunks()
    {
        var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("N", "");
        var note = store.CreateNote(nb.Id!.Value, "T", "original body", NoteOrigin.Manual, null);
        var indexer = new NoteIndexer(store);
        await indexer.IndexAsync(note.Id!.Value);

        store.UpdateNote(note.Id!.Value, "T", "replaced body");
        await indexer.IndexAsync(note.Id!.Value);

        var shadow = store.Source(store.Note(note.Id!.Value)!.AutoSourceId!.Value)!;
        var chunks = store.Chunks(shadow.Id!.Value);
        Assert.Contains(chunks, c => c.Text.Contains("replaced"));
        Assert.DoesNotContain(chunks, c => c.Text.Contains("original"));
    }

    // NoteIndexerTests.testEmptyBodyClearsChunksButKeepsShadow
    [Fact]
    public async Task EmptyBodyClearsChunksButKeepsShadow()
    {
        var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("N", "");
        var note = store.CreateNote(nb.Id!.Value, "T", "has content", NoteOrigin.Manual, null);
        var indexer = new NoteIndexer(store);
        await indexer.IndexAsync(note.Id!.Value);

        store.UpdateNote(note.Id!.Value, "T", "   ");
        await indexer.IndexAsync(note.Id!.Value);

        var shadowId = store.Note(note.Id!.Value)!.AutoSourceId!.Value;
        Assert.NotNull(store.Source(shadowId));
        Assert.Empty(store.Chunks(shadowId));
    }

    // NoteIndexerTests.testKickHookFiresAfterIndex
    [Fact]
    public async Task KickHookFiresAfterIndex()
    {
        var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("N", "");
        var note = store.CreateNote(nb.Id!.Value, "T", "body", NoteOrigin.Manual, null);

        var fired = 0;
        var indexer = new NoteIndexer(store, () => { fired++; return Task.CompletedTask; });
        await indexer.IndexAsync(note.Id!.Value);

        Assert.Equal(1, fired);
    }
}
```

- [ ] **Step 2: Run — Expected: FAIL.**
```
dotnet test windows/tests/AINotebook.Core.Tests --filter "FullyQualifiedName~Rag.ChatEngineTests|FullyQualifiedName~Rag.TransformationEngineTests|FullyQualifiedName~Rag.NoteIndexerTests"
```
Expected: FAIL.

- [ ] **Step 3: Implement `TransformationException`.**

`windows/src/AINotebook.Core/Rag/TransformationException.cs`:
```csharp
namespace AINotebook.Core.Rag;

public abstract class TransformationException : Exception
{
    protected TransformationException(string message) : base(message) { }

    public sealed class SourceNotFound : TransformationException
    {
        public long Id { get; }
        public SourceNotFound(long id) : base($"Source {id} not found.") => Id = id;
    }

    public sealed class TransformationNotFound : TransformationException
    {
        public long Id { get; }
        public TransformationNotFound(long id) : base($"Transformation {id} not found.") => Id = id;
    }

    public sealed class NoChunks : TransformationException
    {
        public long Id { get; }
        public NoChunks(long id) : base($"No chunks for {id}.") => Id = id;
    }
}
```

- [ ] **Step 4: Implement `ChatEngine`.**

`windows/src/AINotebook.Core/Rag/ChatEngine.cs` (ports `ChatEngine.swift`: persist user msg, retrieve, compose, retry-stream, dedupe+bound markers, persist assistant msg):
```csharp
using AINotebook.Core.Models;
using AINotebook.Core.Ollama;

namespace AINotebook.Core.Rag;

public sealed class ChatEngine
{
    private readonly NotebookStore _store;
    private readonly Retriever _retriever;
    private readonly IChatStreaming _chat;
    public string ChatModel { get; }
    public int TopK { get; }
    public int RetryAttempts { get; }
    public int RetryBackoffMillis { get; }

    public ChatEngine(
        NotebookStore store, Retriever retriever, IChatStreaming chat, string chatModel,
        int topK = 8, int retryAttempts = 2, int retryBackoffMillis = 250)
    {
        _store = store;
        _retriever = retriever;
        _chat = chat;
        ChatModel = chatModel;
        TopK = topK;
        RetryAttempts = retryAttempts;
        RetryBackoffMillis = retryBackoffMillis;
    }

    public async Task<ChatMessage> SendAsync(
        long sessionId, long notebookId, string userText,
        string? currentNoteContent = null, Action<string>? onToken = null,
        CancellationToken ct = default)
    {
        // 1) Persist the user message.
        _store.AppendMessage(new ChatMessage(null, sessionId, ChatRole.User, userText, Array.Empty<Citation>(), DateTime.UtcNow));

        // 2) Retrieve context.
        var hits = await _retriever.SearchAsync(notebookId, userText, TopK, ct);

        // 3) Compose messages: system + full history.
        var systemContent = SystemPrompt.Compose(hits, currentNoteContent);
        var history = _store.Messages(sessionId);
        var turns = new List<ChatTurn> { new(ChatRole.System, systemContent) };
        foreach (var m in history) turns.Add(new ChatTurn(m.Role, m.Content));

        // 4) Stream with retry + exponential backoff. total tries = RetryAttempts + 1.
        var assembled = "";
        var attempt = 0;
        while (true)
        {
            try
            {
                var partial = "";
                await foreach (var token in _chat.StreamAsync(ChatModel, turns, ct))
                {
                    partial += token;
                    onToken?.Invoke(token);
                }
                assembled = partial;
                break;
            }
            catch (Exception)
            {
                if (attempt >= RetryAttempts) throw;
                attempt++;
                var delayMs = RetryBackoffMillis * (int)Math.Pow(2, attempt - 1);
                await Task.Delay(delayMs, ct);
            }
        }

        // 5) Parse markers, dedupe first-seen, bound to 1..hits.Count, map to citations.
        var markers = CitationParser.Markers(assembled);
        var seen = new HashSet<int>();
        var citations = new List<Citation>();
        foreach (var m in markers)
        {
            if (!seen.Add(m)) continue;
            if (m < 1 || m > hits.Count) continue;
            var h = hits[m - 1];
            citations.Add(new Citation(m, h.ChunkId, h.SourceId, h.Snippet));
        }

        // 6) Persist the assistant message.
        var stored = new ChatMessage(null, sessionId, ChatRole.Assistant, assembled, citations, DateTime.UtcNow);
        _store.AppendMessage(stored);
        return stored;
    }
}
```

- [ ] **Step 5: Implement `TransformationEngine`.**

`windows/src/AINotebook.Core/Rag/TransformationEngine.cs` (ports `TransformationEngine.swift`; NO system turn; chunk text joined with `"\n\n"`; titles use em-dash U+2014):
```csharp
using AINotebook.Core.Models;
using AINotebook.Core.Ollama;

namespace AINotebook.Core.Rag;

public sealed class TransformationEngine
{
    private readonly NotebookStore _store;
    private readonly IChatStreaming _chat;
    public string ChatModel { get; }

    public TransformationEngine(NotebookStore store, IChatStreaming chat, string chatModel)
    {
        _store = store;
        _chat = chat;
        ChatModel = chatModel;
    }

    public async Task<Note> RunAsync(
        long transformationId, long sourceId, Action<string>? onToken = null, CancellationToken ct = default)
    {
        var transformation = _store.Transformations().FirstOrDefault(t => t.Id == transformationId)
            ?? throw new TransformationException.TransformationNotFound(transformationId);
        var source = _store.Source(sourceId)
            ?? throw new TransformationException.SourceNotFound(sourceId);
        var chunks = _store.Chunks(sourceId);
        if (chunks.Count == 0) throw new TransformationException.NoChunks(sourceId);

        var sourceText = string.Join("\n\n", chunks.Select(c => c.Text));
        var rendered = transformation.PromptTemplate.Replace("{{source_text}}", sourceText);

        var assembled = await StreamAssembleAsync(rendered, onToken, ct);

        // em-dash U+2014 in the title separator.
        var noteTitle = $"{transformation.Name} — {source.Title}";
        var created = _store.CreateNote(source.NotebookId, noteTitle, assembled,
            NoteOrigin.Transformation, transformation.Id);
        _store.RecordTransformationRun(transformation.Id!.Value, source.Id!.Value, created.Id);
        return created;
    }

    public async Task<Note> RunNotebookScopeAsync(
        long transformationId, long notebookId, Action<string>? onToken = null, CancellationToken ct = default)
    {
        var transformation = _store.Transformations().FirstOrDefault(t => t.Id == transformationId)
            ?? throw new TransformationException.TransformationNotFound(transformationId);
        var sources = _store.Sources(notebookId);
        var allChunks = new List<SourceChunk>();
        foreach (var s in sources) allChunks.AddRange(_store.Chunks(s.Id!.Value));
        if (allChunks.Count == 0) throw new TransformationException.NoChunks(notebookId);

        var sourceText = string.Join("\n\n", allChunks.Select(c => c.Text));
        var rendered = transformation.PromptTemplate.Replace("{{source_text}}", sourceText);

        var assembled = await StreamAssembleAsync(rendered, onToken, ct);

        var noteTitle = $"{transformation.Name} — {sources.Count} sources";
        var created = _store.CreateNote(notebookId, noteTitle, assembled,
            NoteOrigin.Transformation, transformation.Id);
        _store.RecordTransformationRun(transformation.Id!.Value, null, created.Id);
        return created;
    }

    public async Task<IReadOnlyList<Note>> RunOnAllSourcesAsync(
        long transformationId, long notebookId, Action<int, int>? onProgress = null, CancellationToken ct = default)
    {
        var sources = _store.Sources(notebookId);
        var total = sources.Count;
        var results = new List<Note>();
        for (var idx = 0; idx < sources.Count; idx++)
        {
            var note = await RunAsync(transformationId, sources[idx].Id!.Value, null, ct);
            results.Add(note);
            onProgress?.Invoke(idx + 1, total);
        }
        return results;
    }

    private async Task<string> StreamAssembleAsync(string rendered, Action<string>? onToken, CancellationToken ct)
    {
        var turns = new List<ChatTurn> { new(ChatRole.User, rendered) }; // NO system turn
        var assembled = "";
        await foreach (var token in _chat.StreamAsync(ChatModel, turns, ct))
        {
            assembled += token;
            onToken?.Invoke(token);
        }
        return assembled;
    }
}
```

- [ ] **Step 6: Implement `NoteIndexer`.**

`windows/src/AINotebook.Core/Rag/NoteIndexer.cs` (ports `NoteIndexer.swift`: shadow source create/link/title-sync, chunk body, replace + ready, fire callback):
```csharp
using AINotebook.Core.Models;
using AINotebook.Core.Ingestion;

namespace AINotebook.Core.Rag;

public sealed class NoteIndexer
{
    private readonly NotebookStore _store;
    private readonly Func<Task>? _onChunksWritten;

    public NoteIndexer(NotebookStore store, Func<Task>? onChunksWritten = null)
    {
        _store = store;
        _onChunksWritten = onChunksWritten;
    }

    public async Task IndexAsync(long noteId, CancellationToken ct = default)
    {
        var note = _store.Note(noteId)
            ?? throw new StoreException.SourceNotFound(noteId);

        long sourceId;
        if (note.AutoSourceId is { } existing && _store.Source(existing) is { } shadow)
        {
            if (shadow.Title != note.Title)
                _store.UpdateSourceTitle(existing, note.Title);
            sourceId = existing;
        }
        else
        {
            var created = _store.CreateSource(note.NotebookId, SourceType.Note, note.Title, null, null);
            sourceId = created.Id!.Value;
            _store.LinkNoteToShadowSource(noteId, sourceId);
        }

        var drafts = string.IsNullOrEmpty(note.BodyMd.Trim())
            ? new List<ChunkDraft>()
            : Chunker.Chunk(note.BodyMd);

        _store.ReplaceChunks(sourceId, drafts);
        _store.UpdateSourceStatus(sourceId, SourceStatus.Ready, null);

        if (_onChunksWritten is not null) await _onChunksWritten();
    }
}
```
> Note: `_store.UpdateSourceTitle(long id, string title)`, `LinkNoteToShadowSource(long noteId, long sourceId)`, and `UpdateSourceStatus(long id, SourceStatus, string?)` are part of the shared `NotebookStore` surface (Writer C owns the store). `Chunker.Chunk` is from the ingestion layer (Writer C). The "note not found" error reuses `StoreException.SourceNotFound`; if the store instead exposes a dedicated note-not-found exception, swap it here.

- [ ] **Step 7: Run — Expected: PASS.**
```
dotnet test windows/tests/AINotebook.Core.Tests --filter "FullyQualifiedName~Rag.ChatEngineTests|FullyQualifiedName~Rag.TransformationEngineTests|FullyQualifiedName~Rag.NoteIndexerTests"
```
Expected: PASS (15 tests).

- [ ] **Step 8: Commit.**
```
git add windows/src/AINotebook.Core/Rag/ChatEngine.cs windows/src/AINotebook.Core/Rag/TransformationEngine.cs windows/src/AINotebook.Core/Rag/TransformationException.cs windows/src/AINotebook.Core/Rag/NoteIndexer.cs windows/tests/AINotebook.Core.Tests/Helpers/ChatStubs.cs windows/tests/AINotebook.Core.Tests/Rag/ChatEngineTests.cs windows/tests/AINotebook.Core.Tests/Rag/TransformationEngineTests.cs windows/tests/AINotebook.Core.Tests/Rag/NoteIndexerTests.cs
git commit -m "feat(core): ChatEngine + TransformationEngine + NoteIndexer

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 26: `LocaleDetection` + `AppLanguage` + `AINotebookVersion` + final integration

Ports `LocaleDetection.swift`, `AppLanguage.swift`, `AINotebookVersion.swift`. `LocaleDetection.DetectInitialLanguage(IEnumerable<string> preferred)` returns `Czech` if any entry's `cs` prefix matches **case-insensitively anywhere in the list** (per gotcha #3 — Czech anywhere wins, not just the first element), else `English`. `AINotebookVersion` is the constant `"0.7.3"` (reads `VERSION` if present, falls back to the pinned literal); its test must be bumped on every release. The final step runs the **entire** `AINotebook.Core.Tests` suite and asserts all-green, then commits, closing Plan 1.

**Files:**
- Create: `windows/src/AINotebook.Core/LocaleDetection.cs`
- Create: `windows/src/AINotebook.Core/AINotebookVersion.cs`
- Test: `windows/tests/AINotebook.Core.Tests/LocaleDetectionTests.cs`
- Test: `windows/tests/AINotebook.Core.Tests/AppLanguageTests.cs` (binds to the Task 2 `AppLanguage` type)
- Test: `windows/tests/AINotebook.Core.Tests/AINotebookVersionTests.cs`
- (`AppLanguage`/`AppLanguageExtensions` are defined in Task 2 — not recreated here.)

- [ ] **Step 1: Write failing tests.**

`windows/tests/AINotebook.Core.Tests/LocaleDetectionTests.cs`:
```csharp
using AINotebook.Core;
using AINotebook.Core.Models;
using Xunit;

namespace AINotebook.Core.Tests;

public class LocaleDetectionTests
{
    [Fact] // testCzechPreferredReturnsCzech
    public void CzechPreferredReturnsCzech() =>
        Assert.Equal(AppLanguage.Czech, LocaleDetection.DetectInitialLanguage(new[] { "cs-CZ", "en-US" }));

    [Fact] // testCzechWithoutRegionReturnsCzech
    public void CzechWithoutRegionReturnsCzech() =>
        Assert.Equal(AppLanguage.Czech, LocaleDetection.DetectInitialLanguage(new[] { "cs" }));

    [Fact] // testEnglishPreferredReturnsEnglish
    public void EnglishPreferredReturnsEnglish() =>
        Assert.Equal(AppLanguage.English, LocaleDetection.DetectInitialLanguage(new[] { "en-US" }));

    [Fact] // testUnknownLanguageDefaultsToEnglish
    public void UnknownLanguageDefaultsToEnglish() =>
        Assert.Equal(AppLanguage.English, LocaleDetection.DetectInitialLanguage(new[] { "ja-JP", "ko-KR" }));

    [Fact] // testEmptyDefaultsToEnglish
    public void EmptyDefaultsToEnglish() =>
        Assert.Equal(AppLanguage.English, LocaleDetection.DetectInitialLanguage(Array.Empty<string>()));

    [Fact] // testCzechSecondInListStillCountsAsCzech (Czech anywhere wins)
    public void CzechSecondInListStillCountsAsCzech() =>
        Assert.Equal(AppLanguage.Czech, LocaleDetection.DetectInitialLanguage(new[] { "en-US", "cs-CZ" }));
}
```

`windows/tests/AINotebook.Core.Tests/AppLanguageTests.cs`:
```csharp
using AINotebook.Core.Models;
using Xunit;

namespace AINotebook.Core.Tests;

public class AppLanguageTests
{
    [Fact] // testAllCases
    public void AllCases() =>
        Assert.Equal(new[] { AppLanguage.English, AppLanguage.Czech }, Enum.GetValues<AppLanguage>());

    [Fact] // testRawValues
    public void RawValues()
    {
        Assert.Equal("en", AppLanguageExtensions.RawValue(AppLanguage.English));
        Assert.Equal("cs", AppLanguageExtensions.RawValue(AppLanguage.Czech));
    }

    [Fact] // testDisplayNames
    public void DisplayNames()
    {
        Assert.Equal("English", AppLanguageExtensions.DisplayName(AppLanguage.English));
        Assert.Equal("Čeština", AppLanguageExtensions.DisplayName(AppLanguage.Czech));
    }
}
```

`windows/tests/AINotebook.Core.Tests/AINotebookVersionTests.cs`:
```csharp
using AINotebook.Core;
using Xunit;

namespace AINotebook.Core.Tests;

public class AINotebookVersionTests
{
    // AINotebookVersionTests.testVersionMatchesExpected — UPDATE when version bumps.
    [Fact]
    public void VersionMatchesExpected() => Assert.Equal("0.7.3", AINotebookVersion.Current);
}
```

- [ ] **Step 2: Run — Expected: FAIL.**
```
dotnet test windows/tests/AINotebook.Core.Tests --filter "FullyQualifiedName~LocaleDetectionTests|FullyQualifiedName~AppLanguageTests|FullyQualifiedName~AINotebookVersionTests"
```
Expected: FAIL.

- [ ] **Step 3: `AppLanguage` + extensions already exist (defined in Task 2).**

The `AppLanguage` enum and `AppLanguageExtensions` (`RawValue` "en"/"cs", `DisplayName` "English"/"Čeština", and nullable `FromRawValue`) live in `windows/src/AINotebook.Core/Models/AppLanguage.cs` from Task 2 (it is needed earlier by Task 6's NotebookStore ctor and Task 11 seeding). Task 26 does NOT redefine it — `AppLanguageTests` above bind to the Task 2 type. Nothing to create here; proceed.

- [ ] **Step 4: Implement `LocaleDetection`.**

`windows/src/AINotebook.Core/LocaleDetection.cs` (ports `LocaleDetection.swift`; matches `cs` prefix case-insensitively for any entry anywhere in the list):
```csharp
using AINotebook.Core.Models;

namespace AINotebook.Core;

public static class LocaleDetection
{
    /// Czech if any preferred entry starts with "cs" (case-insensitive),
    /// otherwise English.
    public static AppLanguage DetectInitialLanguage(IEnumerable<string> preferred)
    {
        foreach (var entry in preferred)
        {
            if (entry.StartsWith("cs", StringComparison.OrdinalIgnoreCase))
                return AppLanguage.Czech;
        }
        return AppLanguage.English;
    }
}
```

- [ ] **Step 5: Implement `AINotebookVersion`.**

`windows/src/AINotebook.Core/AINotebookVersion.cs` (ports `AINotebookVersion.swift`; pinned literal `"0.7.3"`, the single source the version test asserts against):
```csharp
namespace AINotebook.Core;

/// Bump on each release. The pinned literal is the authoritative version;
/// AINotebookVersionTests.VersionMatchesExpected pins it and MUST be updated
/// on every bump (kept in sync with the repo VERSION file).
public static class AINotebookVersion
{
    public const string Current = "0.7.3";
}
```

- [ ] **Step 6: Run the new tests — Expected: PASS.**
```
dotnet test windows/tests/AINotebook.Core.Tests --filter "FullyQualifiedName~LocaleDetectionTests|FullyQualifiedName~AppLanguageTests|FullyQualifiedName~AINotebookVersionTests"
```
Expected: PASS (10 tests).

- [ ] **Step 7: Run the FULL Core test suite — Expected: ALL PASS.**
```
dotnet test windows/tests/AINotebook.Core.Tests
```
Expected: ALL PASS (entire AINotebook.Core.Tests project — every test ported across Tasks 1-26 green, zero failures). If any test fails, fix it before committing; the suite must be fully green to close Plan 1.

- [ ] **Step 8: Commit.**
```
git add windows/src/AINotebook.Core/LocaleDetection.cs windows/src/AINotebook.Core/AINotebookVersion.cs windows/tests/AINotebook.Core.Tests/LocaleDetectionTests.cs windows/tests/AINotebook.Core.Tests/AppLanguageTests.cs windows/tests/AINotebook.Core.Tests/AINotebookVersionTests.cs
git commit -m "feat(core): LocaleDetection + AppLanguage + AINotebookVersion; full Core suite green

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

**Plan 1 (AINotebook.Core) is complete.** The C# port of `AINotebookCore` now covers models, the SQLite store with FTS5 + migrations, ingestion/extraction, the Ollama HTTP client, and the full RAG + chat + transformation stack — all under faithful 1:1 TDD with the Swift assertions ported verbatim. Two follow-on plans remain: **Plan 2** (the WinUI 3 / Windows App SDK desktop app that consumes this library) and **Plan 3** (MSIX packaging, code signing, and the Ollama-bundling installer). Those build strictly on top of the green `AINotebook.Core` produced here.
