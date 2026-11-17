import { useState } from "react";
import { useStore } from "../store";
import { pickProjectFolder } from "../lib/picker";
import { relativeTime } from "../lib/format";
import { Badge, Kbd, Spinner } from "./ui";
import {
  AlertIcon,
  ArrowRightIcon,
  ExperimentIcon,
  FlowIcon,
  FolderIcon,
  Logo,
  PlayIcon,
  SearchIcon,
  TerminalIcon,
} from "./Icons";

export function Welcome() {
  const boot = useStore((state) => state.boot);
  const booting = useStore((state) => state.booting);
  const bootError = useStore((state) => state.bootError);
  const projects = useStore((state) => state.projects);
  const openProjectPath = useStore((state) => state.openProjectPath);
  const loadSampleProject = useStore((state) => state.loadSampleProject);
  const busy = useStore((state) => state.busy);
  const init = useStore((state) => state.init);
  const [opening, setOpening] = useState(false);

  const browse = async () => {
    if (opening) return;
    setOpening(true);
    const path = await pickProjectFolder();
    setOpening(false);
    if (path) await openProjectPath(path);
  };

  const pythonReady = boot?.python.some((runtime) => runtime.supported) ?? false;

  return (
    <div className="welcome">
      <div className="welcome-grid">
        <section className="welcome-hero">
          <div className="welcome-brand">
            <Logo size={28} />
            <span>Stateglass</span>
          </div>
          <h1>
            See where a value
            <br />
            came from.
          </h1>
          <p className="welcome-lede">
            A debugging workspace for tracing data through a running program and testing
            changes in isolated copies — without touching your original files.
          </p>
          <div className="welcome-actions">
            <button
              type="button"
              className="btn btn-primary btn-lg"
              onClick={browse}
              disabled={busy !== null}
            >
              <FolderIcon size={16} />
              Open project folder
              <Kbd>⌘O</Kbd>
            </button>
            <button
              type="button"
              className="btn btn-secondary btn-lg"
              onClick={() => void loadSampleProject()}
              disabled={busy !== null}
            >
              <ExperimentIcon size={16} />
              Try the sample project
            </button>
          </div>
          <div className="welcome-status">
            {pythonReady ? (
              <Badge tone="success">
                Python {boot?.python.find((runtime) => runtime.supported)?.version ?? "3.11+"} ready
              </Badge>
            ) : (
              <Badge tone="warning">Python 3.11+ not detected</Badge>
            )}
            <Badge tone={boot?.tracerAvailable ? "neutral" : "danger"}>
              {boot?.tracerAvailable ? "Instrumentation helper loaded" : "Instrumentation helper missing"}
            </Badge>
            <span className="welcome-version">v{boot?.version ?? "0.1.0"}</span>
          </div>

          <div className="welcome-features">
            <div>
              <FlowIcon size={15} />
              <span>Trace any variable back through functions and source lines.</span>
            </div>
            <div>
              <ExperimentIcon size={15} />
              <span>Run experiments on a copy and compare both executions side by side.</span>
            </div>
            <div>
              <TerminalIcon size={15} />
              <span>Live output, exit codes, timing and memory for every run.</span>
            </div>
          </div>
        </section>

        <section className="welcome-recent">
          <div className="welcome-recent-header">
            <h2>Recent projects</h2>
            <span className="muted">Local folders only</span>
          </div>

          {booting && (
            <div className="welcome-loading">
              <Spinner size={16} /> Loading workspace…
            </div>
          )}

          {!booting && bootError && (
            <div className="welcome-error">
              <AlertIcon size={16} />
              <div>
                <strong>Could not initialize Stateglass</strong>
                <p>{bootError}</p>
                <button type="button" className="btn btn-ghost btn-sm" onClick={() => void init()}>
                  Retry
                </button>
              </div>
            </div>
          )}

          {!booting && !bootError && projects.length === 0 && (
            <div className="welcome-empty">
              <SearchIcon size={20} />
              <p>No projects yet.</p>
              <span>Open a folder or start with the bundled sample.</span>
            </div>
          )}

          <ul className="project-list">
            {projects.map((project) => (
              <li key={project.id}>
                <button
                  type="button"
                  className="project-list-item"
                  onClick={() => void openProjectPath(project.rootPath)}
                >
                  <span className="project-list-icon">
                    <FolderIcon size={16} />
                  </span>
                  <span className="project-list-body">
                    <span className="project-list-name">{project.name}</span>
                    <span className="project-list-path">{project.rootPath}</span>
                  </span>
                  <span className="project-list-meta">
                    {relativeTime(project.lastOpenedAt)}
                    <ArrowRightIcon size={14} />
                  </span>
                </button>
              </li>
            ))}
          </ul>

          <div className="welcome-shortcuts">
            <span>
              <Kbd>⌘O</Kbd> open folder
            </span>
            <span>
              <Kbd>⌘↵</Kbd> run
            </span>
            <span>
              <Kbd>⌘⇧E</Kbd> experiment
            </span>
            <span>
              <Kbd>?</Kbd> shortcuts
            </span>
          </div>
        </section>
      </div>

      <div className="welcome-footnote">
        <PlayIcon size={12} />
        Stateglass runs project code with your user privileges. It is not a security sandbox.
      </div>
    </div>
  );
}
