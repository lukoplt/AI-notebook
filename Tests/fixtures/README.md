# Shared fixtures

Consumed by BOTH `swift test` (via `#filePath`, see `Tests/AINotebookCoreTests/SharedFixtures.swift`)
and `dotnet test windows/tests/AINotebook.Core.Tests` (linked into the test output as `SharedFixtures/`).

Every contract fixture is a JSON object with an envelope:

    { "contract": "<name>", "version": <int>, ... , "cases": [ { "name": "<unique>", ... } ] }

`constants-v1.json` and `ui-tokens-v1.json` (design tokens, see `docs/design/tokens-v1.md`) have no `cases`. Rules:
- Integers only for anything used in arithmetic (basis points: 10000 bp = 100 %).
- UTF-8, no BOM, LF line endings; strings that test Unicode use literal characters, not escapes, unless the case is about escapes.
- Changing a fixture changes the contract: bump `version` (new file `*-v2.json`), never edit a frozen version.
- Ownership: `lang-*` fixtures = Codex; all others = Claude. Both review.
