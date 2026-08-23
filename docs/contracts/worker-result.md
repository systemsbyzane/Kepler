# WorkerResult contract

A WorkerResult records Plan ID/revision/unit, status, summary, changed paths, discoveries, decisions, failed attempts, handoffs, validation, and memory candidates. It does not contain the worker transcript.

Kepler validates the result before storing it. Only relevant result fields feed downstream ContextPacks; task, file, commit, test, and artifact references remain available for drill-down.
