import { useEffect, useMemo, useState } from "react";
import { useStore } from "../store";
import { api } from "../api";
import type { Project, PythonRuntime } from "../types";
import { argsToString, formatDuration, splitArgs } from "../lib/format";
import { sessionSubtitle, sessionTitle } from "../lib/sessions";
import {
  Badge,
  DropdownSelect,
  IconButton,
  Kbd,
  Popover,
  Spinner,
  StatusDot,
  Toggle,
  Field,
} from "./ui";
import {
  ClockIcon,
  ExperimentIcon,
  KeyboardIcon,
  Logo,
  PanelLeftIcon,
  PanelRightIcon,
  PlayIcon,
  PlusIcon,
  RefreshIcon,
  SearchIcon,
  SettingsIcon,
  StopIcon,
  TerminalIcon,
} from "./Icons";

export function Header() {
  const project = useStore((state) => state.project);
  const workspace = useStore((state) => state.workspace);
  const experiments = useStore((state) => state.experiments);
  const sessions = useStore((state) => state.sessions);
  const activeSession = useStore((state) => state.activeSession);
  const running = activeSession?.status === "running";
  const liveStats = useStore((state) => state.liveStats);
  const run = useStore((state) => state.run);
  const cancelRun = useStore((state) => state.cancelRun);
  const startingRun = useStore((state) => state.startingRun);
  const setWorkspace = useStore((state) => state.setWorkspace);
  const selectSession = useStore((state) => state.selectSession);
  const setNewExperimentOpen = useStore((state) => state.setNewExperimentOpen);
  const setQuickOpenOpen = useStore((state) => state.setQuickOpenOpen);
  const setShortcutsOpen = useStore((state) => state.setShortcutsOpen);
  const runAnalysis = useStore((state) => state.runAnalysis);
  const toggleExplorer = useStore((state) => state.toggleExplorer);
  const toggleInspector = useStore((state) => state.toggleInspector);
  const toggleConsole = useStore((state) => state.toggleConsole);
  const explorerOpen = useStore((state) => state.explorerOpen);
  const inspectorOpen = useStore((state) => state.inspectorOpen);
  const consoleOpen = useStore((state) => state.consoleOpen);
  const analysisError = useStore((state) => state.analysisError);

  const workspaceSessions = useMemo(
    () =>
      sessions.filter((session) =>
        workspace?.kind === "experiment"
          ? session.experimentId === workspace.experimentId
          : session.experimentId === null,
      ),
    [sessions, workspace],
  );

  if (!project || !workspace) return null;

  const experiment =
    workspace.kind === "experiment"
      ? experiments.find((item) => item.id === workspace.experimentId) ?? null
      : null;

  const workspaceOptions = [
    {
      value: "original",
      label: "Original project",
      description: project.rootPath,
      meta: <Badge tone="neutral">read-only source</Badge>,
    },
    ...experiments.map((item) => ({
      value: item.id,
      label: item.name,
      description: item.path,
      meta: <Badge tone="violet">copy</Badge>,
    })),
  ];

  const sessionOptions = workspaceSessions.map((session) => ({
    value: session.id,
    label: sessionTitle(session, experiments),
    description: sessionSubtitle(session),
    meta: (
      <span className="session-option-meta">
        <StatusDot status={session.status} />
        <span>{formatDuration(session.durationMs)}</span>
      </span>
    ),
  }));

  return (
    <header className="app-header">
      <div className="header-left">
        <div className="brand" title="Stateglass">
          <Logo size={22} />
          <span className="brand-name">Stateglass</span>
        </div>
        <div className="header-divider" />
        <div className="project-identity">
          <div className="project-name-row">
            <span className="project-name">{project.name}</span>
            {experiment ? (
              <Badge tone="violet">Experiment copy</Badge>
            ) : (
              <Badge tone="neutral">Original</Badge>
            )}
          </div>
          <span className="project-path" title={workspace.root}>
            {prettyPath(workspace.root)}
          </span>
        </div>
        {experiments.length > 0 && (
          <div className="workspace-switch">
            <DropdownSelect
              value={workspace.kind === "experiment" ? workspace.experimentId ?? "" : "original"}
              options={workspaceOptions}
              onChange={(value) => void setWorkspace(value === "original" ? null : value)}
              width={360}
              align="left"
              className="workspace-dropdown"
              renderValue={(option) => (
                <span className="workspace-value">
                  <span className="muted tiny">Workspace</span>
                  <span>{option?.label ?? "Original project"}</span>
                </span>
              )}
            />
          </div>
        )}
      </div>

      <div className="header-center">
        <div className="run-cluster">
          <Popover
            align="left"
            width={430}
            className="run-settings-panel"
            trigger={() => (
              <button type="button" className="btn btn-ghost run-settings-trigger">
                <SettingsIcon size={15} />
                <span className="run-command">{project.entryPoint ?? "No entry point"}</span>
              </button>
            )}
          >
            {(close) => <RunSettings project={project} onClose={close} />}
          </Popover>

          {running ? (
            <button type="button" className="btn btn-primary btn-run running" onClick={() => void cancelRun()}>
              <StopIcon size={14} />
              Stop
              <span className="run-elapsed">
                {formatDuration(liveStats?.elapsedMs ?? 0)}
              </span>
            </button>
          ) : (
            <button
              type="button"
              className="btn btn-primary btn-run"
              onClick={() => void run()}
              disabled={startingRun}
              title="Run with tracing (⌘↵)"
            >
              {startingRun ? <Spinner size={14} /> : <PlayIcon size={14} />}
              {experiment ? "Run experiment" : "Run"}
              <Kbd>⌘↵</Kbd>
            </button>
          )}
        </div>

        <DropdownSelect
          value={activeSession?.id ?? null}
          options={sessionOptions}
          onChange={(value) => void selectSession(value)}
          placeholder={workspaceSessions.length === 0 ? "No runs yet" : "Select a run"}
          width={360}
          align="left"
          className="session-dropdown"
          renderValue={(option) =>
            option ? (
              <span className="session-value">
                <StatusDot status={workspaceSessions.find((s) => s.id === option.value)?.status ?? "ok"} />
                <span className="session-value-label">{option.label}</span>
                <span className="session-value-meta">
                  {option.description?.split(" · ")[0] ?? ""}
                </span>
              </span>
            ) : (
              <span className="muted">Select a run</span>
            )
          }
        />

        <button
          type="button"
          className="btn btn-secondary btn-sm"
          onClick={() => setNewExperimentOpen(true)}
          title="Create an isolated experiment copy (⌘⇧E)"
        >
          <PlusIcon size={14} />
          <ExperimentIcon size={14} />
          Experiment
        </button>
      </div>

      <div className="header-right">
        <div className="header-metrics">
          {activeSession && activeSession.status !== "running" && (
            <>
              <span className="metric" title="Duration">
                <ClockIcon size={13} />
                {formatDuration(activeSession.durationMs)}
              </span>
              <span className="metric" title="Peak memory (this process)">
                {Math.round((activeSession.peakMemoryBytes ?? 0) / 1024 / 1024)} MB
              </span>
            </>
          )}
          {running && (
            <span className="metric running-metric">
              <span className="status-dot status-accent pulsing" />
              {formatDuration(liveStats?.elapsedMs ?? 0)}
            </span>
          )}
        </div>
        <IconButton
          title="Quick open file (⌘P)"
          onClick={() => setQuickOpenOpen(true)}
        >
          <SearchIcon size={15} />
        </IconButton>
        <IconButton
          title={analysisError ? `Analysis issue: ${analysisError}` : "Re-analyze project for data flow"}
          onClick={() => void runAnalysis()}
        >
          <RefreshIcon size={15} className={analysisError ? "text-warning" : ""} />
        </IconButton>
        <IconButton title="Toggle project explorer (⌘B)" onClick={toggleExplorer} active={explorerOpen}>
          <PanelLeftIcon size={15} />
        </IconButton>
        <IconButton
          title="Toggle inspector (⌘⇧B)"
          onClick={toggleInspector}
          active={inspectorOpen}
        >
          <PanelRightIcon size={15} />
        </IconButton>
        <IconButton title="Toggle console (⌘J)" onClick={toggleConsole} active={consoleOpen}>
          <TerminalIcon size={15} />
        </IconButton>
        <IconButton title="Keyboard shortcuts (?)" onClick={() => setShortcutsOpen(true)}>
          <KeyboardIcon size={15} />
        </IconButton>
      </div>
    </header>
  );
}

function prettyPath(path: string): string {
  const parts = path.split("/").filter(Boolean);
  if (parts.length <= 3) return path;
  return `…/${parts.slice(-3).join("/")}`;
}

function RunSettings({ project, onClose }: { project: Project; onClose: () => void }) {
  const files = useStore((state) => state.files);
  const boot = useStore((state) => state.boot);
  const workspace = useStore((state) => state.workspace);
  const experiments = useStore((state) => state.experiments);
  const sessions = useStore((state) => state.sessions);
  const updateConfig = useStore((state) => state.updateConfig);
  const runStdin = useStore((state) => state.runStdin);
  const setRunStdin = useStore((state) => state.setRunStdin);

  const [entry, setEntry] = useState(project.entryPoint ?? "");
  const [argsText, setArgsText] = useState(argsToString(project.runArgs));
  const [timeoutSeconds, setTimeoutSeconds] = useState(Math.round(project.timeoutMs / 1000));
  const [tracing, setTracing] = useState(project.tracing);
  const [python, setPython] = useState(project.pythonPath ?? "");
  const [saving, setSaving] = useState(false);
  const bootRuntimes = boot?.python;

  const [projectRuntimes, setProjectRuntimes] = useState<PythonRuntime[]>([]);

  useEffect(() => {
    let cancelled = false;
    void api
      .listPythonRuntimes(project.id)
      .then((runtimes) => {
        if (!cancelled) setProjectRuntimes(runtimes);
      })
      .catch(() => undefined);
    return () => {
      cancelled = true;
    };
  }, [project.id]);

  const pythonRuntimes = useMemo(() => {
    const seen = new Set<string>();
    const merged: PythonRuntime[] = [];
    for (const runtime of [...projectRuntimes, ...(bootRuntimes ?? [])]) {
      if (seen.has(runtime.path)) continue;
      seen.add(runtime.path);
      merged.push(runtime);
    }
    return merged;
  }, [projectRuntimes, bootRuntimes]);

  useEffect(() => {
    setEntry(project.entryPoint ?? "");
    setArgsText(argsToString(project.runArgs));
    setTimeoutSeconds(Math.round(project.timeoutMs / 1000));
    setTracing(project.tracing);
    setPython(project.pythonPath ?? "");
  }, [project]);

  const experiment =
    workspace?.kind === "experiment"
      ? experiments.find((item) => item.id === workspace.experimentId) ?? null
      : null;
  const baseline = experiment
    ? sessions.find((session) => session.id === experiment.baselineSessionId) ?? null
    : null;

  if (experiment) {
    return (
      <div className="run-settings">
        <div className="run-settings-heading">
          <h3>Experiment settings</h3>
          <Badge tone="violet">Read-only replay</Badge>
        </div>
        <p className="muted small">
          This experiment replays the baseline command, arguments, stdin and timeout. Edit the
          copy&apos;s source files instead; run settings belong to the original project.
        </p>
        <div className="readonly-grid">
          <span>Entry point</span>
          <code>{baseline?.entryFile ?? project.entryPoint ?? "—"}</code>
          <span>Arguments</span>
          <code>{baseline && baseline.args.length > 0 ? argsToString(baseline.args) : "—"}</code>
          <span>Timeout</span>
          <code>{formatDuration(baseline?.timeoutMs ?? project.timeoutMs)}</code>
          <span>Interpreter</span>
          <code>{baseline?.python ?? "auto-detect"}</code>
        </div>
        <div className="run-settings-footer">
          <button type="button" className="btn btn-ghost btn-sm" onClick={onClose}>
            Close
          </button>
        </div>
      </div>
    );
  }

  const entryOptions = files
    .filter((file) => !file.isDir && file.isPython)
    .map((file) => ({ value: file.path, label: file.path }));

  if (entry && !entryOptions.some((option) => option.value === entry)) {
    entryOptions.unshift({ value: entry, label: entry });
  }

  const pythonOptions = [
    { value: "", label: "Auto-detect (recommended)", description: "Project venv, then newest Python 3.11+" },
    ...pythonRuntimes.map((runtime) => ({
      value: runtime.path,
      label: `${runtime.version ?? "Python"} · ${runtime.path}`,
      description: runtime.supported ? runtime.source : `${runtime.source} · unsupported (needs 3.11+)`,
      disabled: !runtime.supported,
    })),
  ];

  const save = async () => {
    setSaving(true);
    await updateConfig({
      entryPoint: entry || null,
      runArgs: splitArgs(argsText),
      timeoutMs: Math.min(600, Math.max(1, Number(timeoutSeconds) || 20)) * 1000,
      tracing,
      pythonPath: python || null,
    });
    setSaving(false);
    onClose();
  };

  return (
    <div className="run-settings">
      <div className="run-settings-heading">
        <h3>Run settings</h3>
        <Badge tone="neutral">{project.language === "python" ? "Python" : project.language}</Badge>
      </div>

      <Field label="Entry point" hint="The file passed to the interpreter.">
        <DropdownSelect
          value={entry || null}
          options={entryOptions}
          onChange={setEntry}
          placeholder="Choose a Python file"
          width={380}
          align="left"
        />
      </Field>

      <Field label="Arguments" hint="Split on spaces; quotes are preserved.">
        <input
          className="input mono"
          value={argsText}
          onChange={(event) => setArgsText(event.target.value)}
          placeholder="--flag value"
          spellCheck={false}
        />
      </Field>

      <div className="field-row">
        <Field label="Timeout" hint="Seconds, 1–600.">
          <input
            className="input"
            type="number"
            min={1}
            max={600}
            value={timeoutSeconds}
            onChange={(event) => setTimeoutSeconds(Number(event.target.value))}
          />
        </Field>
        <Field label="Interpreter" hint="Defaults to the newest supported Python.">
          <DropdownSelect
            value={python || ""}
            options={pythonOptions}
            onChange={setPython}
            width={360}
            align="left"
          />
        </Field>
      </div>

      {!experiment && (
        <Field label="Standard input" hint="Sent to the process, then closed. Stored with the run.">
          <textarea
            className="input textarea mono"
            rows={3}
            value={runStdin}
            onChange={(event) => setRunStdin(event.target.value)}
            placeholder="Optional stdin"
            spellCheck={false}
          />
        </Field>
      )}

      <Toggle
        checked={tracing}
        onChange={setTracing}
        label="Capture execution trace"
        description="Records variable changes, calls and exceptions. Disable for faster untraced runs."
      />

      <div className="run-settings-footer">
        <button type="button" className="btn btn-ghost btn-sm" onClick={onClose}>
          Cancel
        </button>
        <button type="button" className="btn btn-primary btn-sm" onClick={() => void save()} disabled={saving}>
          {saving ? <Spinner size={13} /> : <PlayIcon size={13} />}
          Save settings
        </button>
      </div>
    </div>
  );
}
