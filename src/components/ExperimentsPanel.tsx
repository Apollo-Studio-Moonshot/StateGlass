import { useMemo } from "react";
import { useStore } from "../store";
import type { Experiment, Session } from "../types";
import { formatDuration, formatShortDate, statusLabel, truncateMiddle } from "../lib/format";
import { experimentRunCount, latestSessionForExperiment } from "../lib/sessions";
import { Badge, EmptyState, IconButton, PanelHeader, StatusDot } from "./ui";
import {
  ArrowRightIcon,
  CompareIcon,
  ExperimentIcon,
  PlayIcon,
  PlusIcon,
  RefreshIcon,
} from "./Icons";

export function ExperimentsPanel() {
  const project = useStore((state) => state.project);
  const experiments = useStore((state) => state.experiments);
  const sessions = useStore((state) => state.sessions);
  const workspace = useStore((state) => state.workspace);
  const setWorkspace = useStore((state) => state.setWorkspace);
  const setNewExperimentOpen = useStore((state) => state.setNewExperimentOpen);
  const setComparePair = useStore((state) => state.setComparePair);
  const selectSession = useStore((state) => state.selectSession);
  const run = useStore((state) => state.run);
  const notify = useStore((state) => state.notify);
  const refreshExperiments = useStore((state) => state.refreshExperiments);
  const refreshSessions = useStore((state) => state.refreshSessions);

  const baselines = useMemo(
    () => sessions.filter((session) => session.kind === "baseline" && session.status !== "running"),
    [sessions],
  );

  const baselineById = useMemo(() => {
    const map = new Map<string, Session>();
    for (const session of sessions) map.set(session.id, session);
    return map;
  }, [sessions]);

  const runExperiment = async (experiment: Experiment) => {
    if (workspace?.experimentId !== experiment.id) {
      await setWorkspace(experiment.id);
    }
    await run();
  };

  const compare = async (experiment: Experiment) => {
    const run = latestSessionForExperiment(sessions, experiment.id);
    if (!run) {
      notify("Run this experiment before comparing it", "info");
      return;
    }
    await setComparePair(experiment.baselineSessionId, run.id);
  };

  if (!project) return null;

  return (
    <div className="experiments-panel">
      <PanelHeader
        title="Experiments"
        icon={<ExperimentIcon size={14} />}
        count={experiments.length}
        actions={
          <>
            <IconButton
              title="Refresh experiment history"
              onClick={() => {
                void refreshExperiments();
                void refreshSessions();
              }}
            >
              <RefreshIcon size={14} />
            </IconButton>
            <button
              type="button"
              className="btn btn-primary btn-sm"
              onClick={() => setNewExperimentOpen(true)}
            >
              <PlusIcon size={13} />
              New experiment
            </button>
          </>
        }
      />

      <div className="experiments-intro">
        <ExperimentIcon size={16} />
        <div>
          <strong>Every experiment is an isolated copy.</strong>
          <p>
            Stateglass copies the project into its own data directory, runs it with the
            recorded baseline command, and leaves your original files untouched. Nothing is
            deleted, so you can keep as many variants as you need.
          </p>
        </div>
      </div>

      {baselines.length === 0 && (
        <div className="experiments-warning">
          Run the original project at least once to record a baseline. Experiments replay a
          baseline&apos;s entry point, arguments, stdin and timeout.
        </div>
      )}

      {experiments.length === 0 ? (
        <EmptyState
          icon={<ExperimentIcon size={26} />}
          title="No experiments yet"
          description="Create a copy of the project, change its code, and compare the result against a recorded baseline."
          actions={
            <button
              type="button"
              className="btn btn-primary"
              onClick={() => setNewExperimentOpen(true)}
              disabled={baselines.length === 0}
              title={baselines.length === 0 ? "Record a baseline first" : "Create an experiment"}
            >
              <PlusIcon size={14} />
              Create the first experiment
            </button>
          }
        />
      ) : (
        <div className="experiment-list">
          {experiments.map((experiment) => {
            const baseline = baselineById.get(experiment.baselineSessionId) ?? null;
            const latest = latestSessionForExperiment(sessions, experiment.id);
            const runCount = experimentRunCount(sessions, experiment.id);
            const active = workspace?.experimentId === experiment.id;
            return (
              <article
                key={experiment.id}
                className={`experiment-card${active ? " active" : ""}`}
              >
                <div className="experiment-card-head">
                  <div className="experiment-title">
                    <ExperimentIcon size={15} />
                    <h3>{experiment.name}</h3>
                    {active && <Badge tone="violet">Editing</Badge>}
                  </div>
                  <span className="experiment-created">
                    {formatShortDate(experiment.createdAt)}
                  </span>
                </div>

                {experiment.note && <p className="experiment-note">{experiment.note}</p>}

                <div className="experiment-meta">
                  <span>
                    <span className="meta-label">Baseline</span>
                    {baseline ? (
                      <span className="meta-value">
                        {formatShortDate(baseline.startedAt)} · {formatDuration(baseline.durationMs)}
                      </span>
                    ) : (
                      <span className="meta-value muted">session missing</span>
                    )}
                  </span>
                  <span>
                    <span className="meta-label">Runs</span>
                    <span className="meta-value">{runCount}</span>
                  </span>
                  <span>
                    <span className="meta-label">Latest</span>
                    {latest ? (
                      <span className="meta-value latest-value">
                        <StatusDot status={latest.status} />
                        {statusLabel(latest.status)} · {formatDuration(latest.durationMs)}
                      </span>
                    ) : (
                      <span className="meta-value muted">not run yet</span>
                    )}
                  </span>
                  <span className="experiment-path" title={experiment.path}>
                    {truncateMiddle(experiment.path, 62)}
                  </span>
                </div>

                <div className="experiment-actions">
                  <button
                    type="button"
                    className="btn btn-secondary btn-sm"
                    onClick={() => {
                      if (!active) void setWorkspace(experiment.id);
                    }}
                    disabled={active}
                  >
                    <ArrowRightIcon size={13} />
                    {active ? "Editing copy" : "Edit copy"}
                  </button>
                  <button
                    type="button"
                    className="btn btn-primary btn-sm"
                    onClick={() => void runExperiment(experiment)}
                  >
                    <PlayIcon size={12} />
                    Run experiment
                  </button>
                  <button
                    type="button"
                    className="btn btn-secondary btn-sm"
                    onClick={() => void compare(experiment)}
                    disabled={!latest}
                    title={latest ? "Compare with the baseline" : "Run the experiment first"}
                  >
                    <CompareIcon size={13} />
                    Compare
                  </button>
                  {latest && (
                    <button
                      type="button"
                      className="btn btn-ghost btn-sm"
                      onClick={async () => {
                        if (!active) await setWorkspace(experiment.id);
                        await selectSession(latest.id);
                      }}
                    >
                      Inspect latest run
                    </button>
                  )}
                </div>
              </article>
            );
          })}
        </div>
      )}
    </div>
  );
}
