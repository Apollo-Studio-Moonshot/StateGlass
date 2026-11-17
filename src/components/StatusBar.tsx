import { useStore } from "../store";
import { basename, formatBytes, formatDuration, statusLabel, truncateMiddle } from "../lib/format";
import { Badge, StatusDot } from "./ui";
import { AlertIcon, CheckIcon, PythonIcon } from "./Icons";

export function StatusBar() {
  const boot = useStore((state) => state.boot);
  const project = useStore((state) => state.project);
  const workspace = useStore((state) => state.workspace);
  const session = useStore((state) => state.activeSession);
  const analysis = useStore((state) => state.analysis);
  const analysisError = useStore((state) => state.analysisError);

  if (!project || !workspace) return null;

  const python = session?.python ?? project.pythonPath ?? boot?.python.find((runtime) => runtime.supported)?.path ?? "";
  const runtime = boot?.python.find((candidate) => candidate.path === python);
  const version = runtime?.version ?? boot?.python.find((candidate) => candidate.supported)?.version;

  return (
    <footer className="status-bar">
      <div className="status-left">
        <span className="status-mode">
          {workspace.kind === "experiment" ? (
            <Badge tone="violet">Experiment</Badge>
          ) : (
            <Badge tone="neutral">Original</Badge>
          )}
        </span>
        <span className="status-path" title={workspace.root}>
          {truncateMiddle(workspace.root, 64)}
        </span>
        {analysis && (
          <span className="status-analysis" title={analysisError ?? "Static analysis metadata"}>
            {analysisError ? <AlertIcon size={11} /> : <CheckIcon size={11} />}
            {analysis.assignments.toLocaleString()} assignments · {analysis.files} files
          </span>
        )}
      </div>

      <div className="status-right">
        <span className="status-item" title={python || "No Python interpreter"}>
          <PythonIcon size={12} />
          {basename(python) || "python"} {version ? `· ${version}` : ""}
        </span>
        <span className="status-item" title={boot?.tracerPath ?? "Instrumentation helper"}>
          <span className={`status-dot ${boot?.tracerAvailable ? "status-success" : "status-danger"}`} />
          tracer
        </span>
        {session && (
          <>
            <span className="status-item" title={session.command}>
              <StatusDot status={session.status} />
              {statusLabel(session.status)}
              {session.exitCode !== null ? ` (${session.exitCode})` : ""}
            </span>
            <span className="status-item" title="Recorded trace events">
              {session.traceEventCount.toLocaleString()} events
            </span>
            {session.peakMemoryBytes !== null && (
              <span className="status-item" title="Peak child-process memory">
                {formatBytes(session.peakMemoryBytes)}
              </span>
            )}
            {session.durationMs !== null && (
              <span className="status-item">{formatDuration(session.durationMs)}</span>
            )}
          </>
        )}
        <span className="status-item muted">v{boot?.version ?? "0.1.0"}</span>
      </div>
    </footer>
  );
}
