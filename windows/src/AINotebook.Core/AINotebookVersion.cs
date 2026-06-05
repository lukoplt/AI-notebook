namespace AINotebook.Core;

/// Bump on each release. The pinned literal is the authoritative version;
/// AINotebookVersionTests.VersionMatchesExpected pins it and MUST be updated
/// on every bump (kept in sync with the repo VERSION file).
public static class AINotebookVersion
{
    public const string Current = "0.7.3";
}
