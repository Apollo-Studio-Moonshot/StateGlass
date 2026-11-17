import { useEffect, useMemo, useRef, useState } from "react";
import { useStore } from "../store";
import { formatDuration, formatShortDate } from "../lib/format";
import { rankQuickOpenFiles } from "../lib/quick-open";
import { completedBaselines, sessionTitle } from "../lib/sessions";
import { Badge, DropdownSelect, Field, Kbd, Modal, Spinner } from "./ui";
import { AlertIcon, ExperimentIcon, FileIcon, PlayIcon, PythonIcon } from "./Icons";

export function Dialogs() {
  const project = useStore((state) => state.project);
  const consentOpen = useStore((state) => state.consentOpen);
  const newExperimentOpen = useStore((state) => state.newExperimentOpen);
  const quickOpenOpen = useStore((state) => state.quickOpenOpen);
  const shortcutsOpen = useStore((state) => state.shortcutsOpen);

  return (
    <>
      {consentOpen && project && <ConsentDialog />}
      {newExperimentOpen && project && <NewExperimentDialog />}
      {quickOpenOpen && project && <QuickOpenDialog />}
      {shortcutsOpen && <ShortcutsDialog />}
    </>
  );
}

function QuickOpenDialog() {
  const close = useStore((state) => state.setQuickOpenOpen);
  const files = useStore((state) => state.files);
  const openFiles = useStore((state) => state.openFiles);
  const activeFile = useStore((state) => state.activeFile);
  const openFile = useStore((state) => state.openFile);
  const [query, setQuery] = useState("");
  const [selectedIndex, setSelectedIndex] = useState(0);
  const resultsRef = useRef<HTMLDivElement>(null);
  const openPaths = useMemo(() => openFiles.map((file) => file.path), [openFiles]);
  const matches = useMemo(
    () => rankQuickOpenFiles(files, query, openPaths, activeFile),
    [files, query, openPaths, activeFile],
  );
  const visibleMatches = matches.slice(0, 50);

  useEffect(() => {
    setSelectedIndex(0);
  }, [query]);

  useEffect(() => {
    resultsRef.current
      ?.querySelector('[aria-selected="true"]')
      ?.scrollIntoView({ block: "nearest" });
  }, [selectedIndex]);

  const openSelected = () => {
    const file = visibleMatches[selectedIndex];
    if (!file) return;
    close(false);
    void openFile(file.path);
  };

  return (
    <Modal
      title="Quick Open"
      subtitle="Search files in this workspace"
      onClose={() => close(false)}
      width={620}
    >
      <div className="quick-open-dialog">
        <input
          autoFocus
          className="input quick-open-input"
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === "ArrowDown" && visibleMatches.length > 0) {
              event.preventDefault();
              setSelectedIndex((index) => (index + 1) % visibleMatches.length);
            } else if (event.key === "ArrowUp" && visibleMatches.length > 0) {
              event.preventDefault();
              setSelectedIndex(
                (index) => (index - 1 + visibleMatches.length) % visibleMatches.length,
              );
            } else if (event.key === "Enter") {
              event.preventDefault();
              openSelected();
            }
          }}
          placeholder="Type a file name or path…"
          aria-label="Search workspace files"
          spellCheck={false}
        />
        <div
          className="quick-open-results"
          role="listbox"
          aria-label="Matching files"
          ref={resultsRef}
        >
          {visibleMatches.map((file, index) => {
            const isOpen = openPaths.includes(file.path);
            return (
              <button
                type="button"
                key={file.path}
                role="option"
                aria-selected={selectedIndex === index}
                className={`quick-open-option${selectedIndex === index ? " selected" : ""}`}
                onMouseEnter={() => setSelectedIndex(index)}
                onClick={() => {
                  setSelectedIndex(index);
                  close(false);
                  void openFile(file.path);
                }}
              >
                {file.isPython ? <PythonIcon size={14} /> : <FileIcon size={14} />}
                <span className="quick-open-name">{file.name}</span>
                <span className="quick-open-path">{file.path}</span>
                {isOpen && <span className="quick-open-open-label">Open</span>}
              </button>
            );
          })}
          {matches.length === 0 && <div className="quick-open-empty">No matching files</div>}
          {matches.length > visibleMatches.length && (
            <div className="quick-open-count">Showing 50 of {matches.length} matches</div>
          )}
        </div>
        <div className="quick-open-hint">
          <span>
            <Kbd>↑</Kbd> <Kbd>↓</Kbd> to navigate
          </span>
          <span>
            <Kbd>↵</Kbd> to open
          </span>
          <span>
            <Kbd>Esc</Kbd> to close
          </span>
        </div>
      </div>
    </Modal>
  );
}

function ConsentDialog() {
  const project = useStore((state) => state.project);
  const close = useStore((state) => state.closeConsent);
  const grantAndRun = useStore((state) => state.grantConsentAndRun);
  const [accepted, setAccepted] = useState(false);
  const [working, setWorking] = useState(false);

  useEffect(() => {
    setAccepted(false);
    setWorking(false);
  }, []);

  const confirm = async () => {
    setWorking(true);
    await grantAndRun();
    setWorking(false);
  };

  if (!project) return null;

  return (
    <Modal
      title="Run project code?"
      subtitle={`${project.name} · Python project`}
      onClose={close}
      width={600}
      tone="warning"
      footer={
        <>
          <button type="button" className="btn btn-ghost" onClick={close}>
            Cancel
          </button>
          <button
            type="button"
            className="btn btn-primary"
            disabled={!accepted || working}
            onClick={() => void confirm()}
          >
            {working ? <Spinner size={13} /> : <PlayIcon size={13} />}
            Run with tracing
          </button>
        </>
      }
    >
      <div className="consent-body">
        <div className="consent-hero">
          <span className="consent-icon">
            <AlertIcon size={20} />
          </span>
          <p>
            Stateglass is a development tool, <strong>not a security sandbox</strong>. The
            program runs as a child process with your user account and can read, modify or
            delete files and access the network according to your permissions.
          </p>
        </div>

        <ul className="consent-list">
          <li>
            <strong>Instrumentation</strong>
            <span>
              The Python tracer observes executed lines, function calls and local variables.
              Values are stored as short summaries, not pickled objects.
            </span>
          </li>
          <li>
            <strong>Local only</strong>
            <span>
              All traces and experiments stay in Stateglass&apos;s application data folder. No
              cloud account or API key is involved.
            </span>
          </li>
          <li>
            <strong>Limits</strong>
            <span>
              Executions are terminated after {formatDuration(project.timeoutMs)} by default.
              External services, databases and nondeterministic behavior can make replays differ.
            </span>
          </li>
        </ul>

        <label className="consent-check">
          <input
            type="checkbox"
            checked={accepted}
            onChange={(event) => setAccepted(event.target.checked)}
          />
          <span>
            I understand this program will run with my privileges and that tracing is not a
            security boundary.
          </span>
        </label>

        <p className="consent-path">
          <PythonIcon size={13} /> {project.rootPath}
        </p>
      </div>
    </Modal>
  );
}

function NewExperimentDialog() {
  const project = useStore((state) => state.project);
  const experiments = useStore((state) => state.experiments);
  const sessions = useStore((state) => state.sessions);
  const close = useStore((state) => state.setNewExperimentOpen);
  const createExperiment = useStore((state) => state.createExperiment);
  const run = useStore((state) => state.run);
  const setCenterTab = useStore((state) => state.setCenterTab);

  const baselines = useMemo(() => completedBaselines(sessions), [sessions]);
  const defaultBaseline = baselines[0]?.id ?? "";
  const [name, setName] = useState(`Experiment ${experiments.length + 1}`);
  const [note, setNote] = useState("");
  const [baselineId, setBaselineId] = useState(defaultBaseline);
  const [working, setWorking] = useState(false);

  useEffect(() => {
    setBaselineId((current) =>
      current && baselines.some((session) => session.id === current) ? current : defaultBaseline,
    );
  }, [baselines, defaultBaseline]);

  if (!project) return null;

  const create = async () => {
    if (!baselineId) return;
    setWorking(true);
    const created = await createExperiment(name, note, baselineId);
    setWorking(false);
    if (created) {
      close(false);
      setCenterTab("editor");
    }
  };

  return (
    <Modal
      title="New experiment"
      subtitle="Create an isolated copy and replay a baseline execution"
      onClose={() => close(false)}
      width={620}
      footer={
        <>
          <button type="button" className="btn btn-ghost" onClick={() => close(false)}>
            Cancel
          </button>
          <button
            type="button"
            className="btn btn-primary"
            disabled={!baselineId || working || name.trim().length === 0}
            onClick={() => void create()}
          >
            {working ? <Spinner size={13} /> : <ExperimentIcon size={14} />}
            Create experiment copy
          </button>
        </>
      }
    >
      {baselines.length === 0 ? (
        <div className="dialog-empty">
          <AlertIcon size={18} />
          <div>
            <strong>No baseline execution yet</strong>
            <p>
              An experiment needs a recorded run to replay. Run the original project first; the
              recorded entry point, arguments, stdin and timeout are reused automatically.
            </p>
            <button
              type="button"
              className="btn btn-secondary btn-sm"
              onClick={() => {
                close(false);
                void run();
              }}
            >
              <PlayIcon size={13} />
              Run baseline now
            </button>
          </div>
        </div>
      ) : (
        <div className="dialog-form">
          <Field label="Experiment name">
            <input
              className="input"
              value={name}
              onChange={(event) => setName(event.target.value)}
              placeholder="e.g. Fix tax base"
              autoFocus
            />
          </Field>
          <Field label="Note" hint="Optional context for future you.">
            <textarea
              className="input textarea"
              rows={2}
              value={note}
              onChange={(event) => setNote(event.target.value)}
              placeholder="What are you testing?"
            />
          </Field>
          <Field label="Baseline to replay">
            <DropdownSelect
              value={baselineId}
              options={baselines.map((session) => ({
                value: session.id,
                label: `${sessionTitle(session, experiments)} · ${formatShortDate(session.startedAt)}`,
                description: session.command,
                meta: <Badge tone="neutral">{formatDuration(session.durationMs)}</Badge>,
              }))}
              onChange={setBaselineId}
              width={520}
              align="left"
            />
          </Field>

          <div className="dialog-note">
            <ExperimentIcon size={15} />
            <div>
              <strong>Isolation guarantees</strong>
              <p>
                Stateglass copies the project into its own application-data folder. Editing and
                running the experiment never writes to <code>{project.rootPath}</code>. Experiment
                history is kept on disk and in SQLite.
              </p>
            </div>
          </div>
          <div className="dialog-note warning">
            <AlertIcon size={14} />
            <div>
              <p>
                Replays use the same command and stdin, but external services, databases, clocks
                and randomness may still produce different results.
              </p>
            </div>
          </div>
        </div>
      )}
    </Modal>
  );
}

function ShortcutsDialog() {
  const close = useStore((state) => state.setShortcutsOpen);
  const rows: Array<[string, string]> = [
    ["Open project folder", "⌘ O"],
    ["Quick open file", "⌘ P"],
    ["Close active file", "⌘ W"],
    ["Save active file", "⌘ S"],
    ["Run with tracing", "⌘ ↵"],
    ["Cancel execution", "⌘ ."],
    ["New experiment", "⌘ ⇧ E"],
    ["Toggle explorer", "⌘ B"],
    ["Toggle inspector", "⌘ ⇧ B"],
    ["Toggle console", "⌘ J"],
    ["Editor / Data flow / Compare / Experiments", "⌘ 1 … ⌘ 4"],
    ["Move to start / end of line (editor)", "⌘← / ⌘→"],
    ["Shortcuts", "?"],
    ["Close dialog", "Esc"],
  ];
  return (
    <Modal
      title="Keyboard shortcuts"
      onClose={() => close(false)}
      width={480}
      footer={
        <button type="button" className="btn btn-secondary" onClick={() => close(false)}>
          Close
        </button>
      }
    >
      <div className="shortcut-grid">
        {rows.map(([label, keys]) => (
          <div key={label} className="shortcut-row">
            <span>{label}</span>
            <span className="shortcut-keys">
              {keys.split(" ").map((key) => (
                <Kbd key={`${label}-${key}`}>{key}</Kbd>
              ))}
            </span>
          </div>
        ))}
      </div>
      <p className="muted small" style={{ marginTop: 16 }}>
        For app shortcuts, use Ctrl instead of ⌘ on Windows and Linux. Editor shortcuts may differ by platform.
      </p>
    </Modal>
  );
}
