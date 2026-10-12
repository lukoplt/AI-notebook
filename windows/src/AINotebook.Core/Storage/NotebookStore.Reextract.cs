using System.Text.Json;
using AINotebook.Core.Ingestion;
using AINotebook.Core.Models;
using Dapper;

namespace AINotebook.Core.Storage;

public sealed partial class NotebookStore
{
    /// <summary>
    /// Requeues extraction, once per <see cref="ExtractorRevision.Current"/>, for every present, eligible folder source
    /// whose extraction failed with a retryable code and has no unfinished extract job and no extract job stamped with
    /// the current (or a newer) revision. Each new job carries <c>{"extractorRevision": current}</c> so a failure under
    /// this revision is never requeued again. Raises <see cref="FolderIngestionChanged"/> (and thereby
    /// <see cref="IndexingStatusChanged"/>) once per affected notebook. Returns the number of requeued sources.
    /// Contract <c>ingestion-reextract-v1</c>.
    /// </summary>
    public int RequeueUpgradedExtractions(long now)
    {
        var notebooks = new List<long>();
        lock (_gate)
        {
            using var tx = _conn.BeginTransaction(deferred: false);
            var rows = _conn.Query(ReextractCandidatesSql, new
            {
                codes = JsonSerializer.Serialize(ExtractorRevision.RetryableCodes),
                key = ExtractorRevision.OptionsKey,
                revision = (long)ExtractorRevision.Current,
            }, tx).ToList();
            foreach (var row in rows)
            {
                long sourceId = (long)row.id;
                EnqueueDue(tx, new IngestJobDraft("extract", SourceTarget(sourceId), (long?)row.current_revision,
                    ExtractorRevision.OptionsJson), now);
                _conn.Execute("UPDATE sources SET status='pending',error=NULL WHERE id=$sourceId", new { sourceId }, tx);
                notebooks.Add((long)row.notebook_id);
            }
            tx.Commit();
        }
        foreach (long notebook in notebooks.Distinct().Order()) NotifyFolderIngestionChanged(notebook);
        return notebooks.Count;
    }

    /// <summary>
    /// Throttled re-extraction of ready folder spreadsheets whose published revision predates the current spreadsheet
    /// canonical text (<c>text_format_version &lt; ExtractorRevision.SpreadsheetTextVersion</c>). Tops the unfinished
    /// upgrade jobs up to <see cref="ExtractorRevision.SpreadsheetBatchSize"/>, in ascending source id; each job carries
    /// <c>{"spreadsheetTextVersion": 2}</c>. The source stays <c>ready</c> and its published revision stays searchable
    /// until the new revision is published. Runs at runtime start, on every periodic reconciliation and after each
    /// finished upgrade job, so the batch refills as extraction drains. Raises <see cref="FolderIngestionChanged"/> once
    /// per affected notebook. Returns the number of requeued sources. Contract <c>ingestion-reextract-v1</c> §7
    /// (fixture <c>ingestion-reextract-v2</c>).
    /// </summary>
    public int RequeueSpreadsheetUpgrades(long now)
    {
        var notebooks = new List<long>();
        lock (_gate)
        {
            using var tx = _conn.BeginTransaction(deferred: false);
            var args = new
            {
                key = ExtractorRevision.SpreadsheetOptionsKey,
                version = (long)ExtractorRevision.SpreadsheetTextVersion,
                type = SourceType.Xlsx.RawValue(),
            };
            long outstanding = _conn.ExecuteScalar<long>(OutstandingSpreadsheetUpgradesSql, args, tx);
            long room = ExtractorRevision.SpreadsheetBatchSize - outstanding;
            if (room > 0)
            {
                var rows = _conn.Query(SpreadsheetCandidatesSql, new { args.key, args.version, args.type, room }, tx).ToList();
                foreach (var row in rows)
                {
                    long sourceId = (long)row.id;
                    EnqueueDue(tx, new IngestJobDraft("extract", SourceTarget(sourceId), (long?)row.current_revision,
                        ExtractorRevision.SpreadsheetOptionsJson), now);
                    notebooks.Add((long)row.notebook_id);
                }
            }
            tx.Commit();
        }
        foreach (long notebook in notebooks.Distinct().Order()) NotifyFolderIngestionChanged(notebook);
        return notebooks.Count;
    }

    /// <summary>A job's spreadsheet stamp: its integer <c>spreadsheetTextVersion</c> option, else 0.</summary>
    private const string SpreadsheetStampSql = """
        (CASE WHEN json_valid(j.options_json) THEN
             (CASE WHEN json_type(j.options_json,'$.'||$key)='integer'
                   THEN json_extract(j.options_json,'$.'||$key) ELSE 0 END)
         ELSE 0 END)
        """;

    private const string OutstandingSpreadsheetUpgradesSql = """
        SELECT count(*) FROM ingest_jobs j WHERE j.kind='extract'
          AND (j.state IN ('queued','running','paused') OR (j.state='failed' AND j.attempts<5 AND j.next_retry_at IS NOT NULL))
          AND
        """ + SpreadsheetStampSql + ">=$version";

    private const string SpreadsheetCandidatesSql = """
        SELECT s.id,s.notebook_id,s.current_revision FROM sources s
        JOIN source_revisions r ON r.id=s.published_revision_id
        WHERE s.folder_id IS NOT NULL AND s.type=$type AND s.status='ready' AND s.availability='present' AND s.eligible=1
          AND s.current_revision=s.published_revision_id AND r.text_format_version<$version
          AND NOT EXISTS(SELECT 1 FROM ingest_jobs j WHERE j.kind='extract' AND j.target='source:'||s.id
              AND (j.state IN ('queued','running','paused')
                   OR (j.state='failed' AND j.attempts<5 AND j.next_retry_at IS NOT NULL)))
          AND NOT EXISTS(SELECT 1 FROM ingest_jobs j WHERE j.kind='extract' AND j.target='source:'||s.id
              AND j.state='failed' AND
        """ + SpreadsheetStampSql + """
        >=$version)
        ORDER BY s.id LIMIT $room
        """;

    /// <summary>A job's revision is its integer <c>extractorRevision</c> option, else 1.</summary>
    private const string ReextractCandidatesSql = $"""
        SELECT s.id,s.notebook_id,s.current_revision FROM sources s
        WHERE s.folder_id IS NOT NULL AND s.status='error' AND s.availability='present' AND s.eligible=1
          AND {RetryBudgetSQL.BudgetLeftPredicate}
          AND s.error IN (SELECT value FROM json_each($codes))
          AND NOT EXISTS(SELECT 1 FROM ingest_jobs j WHERE j.kind='extract' AND j.target='source:'||s.id
              AND (j.state IN ('queued','running','paused')
                   OR (j.state='failed' AND j.attempts<5 AND j.next_retry_at IS NOT NULL)))
          AND NOT EXISTS(SELECT 1 FROM ingest_jobs j WHERE j.kind='extract' AND j.target='source:'||s.id
              AND (CASE WHEN json_valid(j.options_json) THEN
                        (CASE WHEN json_type(j.options_json,'$.'||$key)='integer'
                              THEN json_extract(j.options_json,'$.'||$key) ELSE 1 END)
                   ELSE 1 END)>=$revision)
        ORDER BY s.id
        """;
}
