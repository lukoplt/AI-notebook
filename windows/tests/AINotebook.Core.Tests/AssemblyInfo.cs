using Xunit;

// NotebookStore's in-memory mode uses a single process-wide shared SQLite
// database ("Data Source=InMemoryAINotebook;Mode=Memory;Cache=Shared"), so
// distinct test classes that each open a store would otherwise race on the same
// database when xUnit runs collections in parallel. Serialize test collections
// to keep the shared in-memory store isolated per test.
[assembly: CollectionBehavior(DisableTestParallelization = true)]
