import { useEffect, useMemo, useState } from "react";
import { useStore } from "../store";
import type { DiffLine, Session } from "../types";
import {
  formatBytes,
  formatDeltaPercent,
  formatDuration,
  formatShortDate,
  statusLabel,
} from "../lib/format";
import { Badge, DropdownSelect, EmptyState, Spinner, StatusDot } from "./ui";
import {
  AlertIcon,
  ArrowRightIcon,
  ClockIcon,
  CompareIcon,
  ExperimentIcon,
  MemoryIcon,
  PlayIcon,
} from "./Icons";

type CompareTab = "output" | "errors" | "variables";

export function ComparePanel() {
  const sessions = useStore((state) => state.sessions);
  const experiments = useStore((state) => state.experiments);
  const compareA = useStore((state) => state.compareA);
  const compareB = useStore((state) => state.compareB);
  const comparison = useStore((state) => state.comparison);
  const loading = useStore((state) => state.comparisonLoading);
  const setComparePair = useStore((state) => state.setComparePair);
  const selectSession = useStore((state) => state.selectSession);
  const setNewExperimentOpen = useStore((state) => state.setNewExperimentOpen);
  const setCenterTab = useStore((state) => state.setCenterTab);

  const [tab, setTab] = useState<CompareTab>("output");
  const [changedOnly, setChangedOnly] = useState(true);
  const [splitDiff, setSplitDiff] = useState(false);
  const [variablesChangedOnly, setVariablesChangedOnly] = useState(true);

  const baselines = useMemo(
    () =>
      sessions.filter(
        (session) => session.kind === "baseline" && session.status !== "running",
      ),
    [sessions],
  );
  const experimentRuns = useMemo(
    () =>
      sessions.filter(
        (session) => session.kind === "experiment" && session.status !== "running",
      ),
    [sessions],
  );

  useEffect(() => {
    if (baselines.length === 0 || experimentRuns.length === 0) return;
    const nextA = compareA && baselines.some((session) => session.id === compareA) ? compareA : baselines[0]!.id;
    const nextB =
      compareB && experimentRuns.some((session) => session.id === compareB)
        ? compareB
        : experimentRuns[0]!.id;
    if (nextA !== compareA || nextB !== compareB) {
      void setComparePair(nextA, nextB);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [baselines, experimentRuns]);

  if (experimentRuns.length === 0) {
    return (
      <div className="compare-panel">
        <EmptyState
          icon={<CompareIcon size={26} />}
          title="Nothing to compare yet"
          description="Create an experiment, run it with the recorded baseline command, then compare output, errors, timing, memory and variable values."
          actions={
            <button type="button" className="btn btn-primary" onClick={() => setNewExperimentOpen(true)}>
              <ExperimentIcon size={14} />
              New experiment
            </button>
          }
        />
      </div>
    );
  }

  const sessionLabel = (session: Session) => {
    const name =
      session.kind === "baseline"
        ? "Baseline"
        : session.label ??
          experiments.find((experiment) => experiment.id === session.experimentId)?.name ??
          "Experiment";
    return `${name} · ${formatShortDate(session.startedAt)}`;
  };

  const baselineOptions = baselines.map((session) => ({
    value: session.id,
    label: sessionLabel(session),
    description: session.command,
    meta: <Badge tone="neutral">{formatDuration(session.durationMs)}</Badge>,
  }));
  const experimentOptions = experimentRuns.map((session) => ({
    value: session.id,
    label: sessionLabel(session),
    description: session.command,
    meta: (
      <span className="compare-option-meta">
        <StatusDot status={session.status} />
        <span>{formatDuration(session.durationMs)}</span>
      </span>
    ),
  }));

  const changedVariables = comparison?.variables.filter((variable) => variable.status !== "same") ?? [];
  const visibleVariables =
    comparison?.variables.filter((variable) => !variablesChangedOnly || variable.status !== "same") ?? [];

  return (
    <div className="compare-panel">
      <div className="compare-toolbar">
        <div className="compare-select">
          <span className="compare-select-label">
            <span className="compare-dot baseline" /> Baseline
          </span>
          <DropdownSelect
            value={compareA}
            options={baselineOptions}
            onChange={(value) => void setComparePair(value, compareB)}
            width={340}
            align="left"
          />
        </div>
        <CompareIcon size={16} className="compare-arrow" />
        <div className="compare-select">
          <span className="compare-select-label">
            <span className="compare-dot experiment" /> Experiment
          </span>
          <DropdownSelect
            value={compareB}
            options={experimentOptions}
            onChange={(value) => void setComparePair(compareA, value)}
            width={340}
            align="left"
          />
        </div>
        <div className="compare-toolbar-spacer" />
        {loading && <Spinner size={14} />}
        {comparison && (
          <div className="compare-open">
            <button
              type="button"
              className="mini-link"
              onClick={() => {
                void selectSession(comparison.baseline.id);
                setCenterTab("editor");
              }}
            >
              Inspect baseline
            </button>
            <button
              type="button"
              className="mini-link"
              onClick={() => {
                void selectSession(comparison.experiment.id);
                setCenterTab("editor");
              }}
            >
              Inspect experiment
            </button>
          </div>
        )}
      </div>

      {!comparison && !loading && (
        <EmptyState
          icon={<CompareIcon size={26} />}
          title="Select two executions"
          description="Pick a recorded baseline and an experiment run to see a side-by-side comparison."
        />
      )}

      {comparison && (
        <div className="compare-content">
          <div className="compare-warnings">
            <AlertIcon size={14} />
            <div>
              {comparison.warnings.map((warning) => (
                <p key={warning}>{warning}</p>
              ))}
            </div>
          </div>

          <div className="metric-grid">
            <MetricCard
              icon={<ClockIcon size={14} />}
              label="Duration"
              baseline={formatDuration(comparison.baselineMetrics.durationMs)}
              experiment={formatDuration(comparison.experimentMetrics.durationMs)}
              delta={formatDeltaPercent(
                comparison.baselineMetrics.durationMs,
                comparison.experimentMetrics.durationMs,
              )}
            />
            <MetricCard
              icon={<MemoryIcon size={14} />}
              label="Peak memory"
              baseline={formatBytes(comparison.baselineMetrics.peakMemoryBytes)}
              experiment={formatBytes(comparison.experimentMetrics.peakMemoryBytes)}
              delta={formatDeltaPercent(
                comparison.baselineMetrics.peakMemoryBytes,
                comparison.experimentMetrics.peakMemoryBytes,
              )}
            />
            <MetricCard
              icon={<PlayIcon size={14} />}
              label="Status"
              baseline={
                <span className="status-inline">
                  <StatusDot status={comparison.baselineMetrics.status} />
                  {statusLabel(comparison.baselineMetrics.status)}
                  {comparison.baselineMetrics.exitCode !== null
                    ? ` · exit ${comparison.baselineMetrics.exitCode}`
                    : ""}
                </span>
              }
              experiment={
                <span className="status-inline">
                  <StatusDot status={comparison.experimentMetrics.status} />
                  {statusLabel(comparison.experimentMetrics.status)}
                  {comparison.experimentMetrics.exitCode !== null
                    ? ` · exit ${comparison.experimentMetrics.exitCode}`
                    : ""}
                </span>
              }
              delta={null}
            />
            <MetricCard
              icon={<ExperimentIcon size={14} />}
              label="Trace events"
              baseline={comparison.baselineMetrics.traceEventCount.toLocaleString()}
              experiment={comparison.experimentMetrics.traceEventCount.toLocaleString()}
              delta={null}
            />
          </div>

          <div className="compare-tabs">
            <button
              type="button"
              className={`compare-tab${tab === "output" ? " active" : ""}`}
              onClick={() => setTab("output")}
            >
              Output
              {comparison.stdoutDivergence !== null && <span className="tab-dot warning" />}
            </button>
            <button
              type="button"
              className={`compare-tab${tab === "errors" ? " active" : ""}`}
              onClick={() => setTab("errors")}
            >
              Errors
              {comparison.experimentMetrics.stderrBytes > comparison.baselineMetrics.stderrBytes && (
                <span className="tab-dot danger" />
              )}
            </button>
            <button
              type="button"
              className={`compare-tab${tab === "variables" ? " active" : ""}`}
              onClick={() => setTab("variables")}
            >
              Variables
              <span className="tab-count">{changedVariables.length}</span>
            </button>
            <div className="compare-tabs-spacer" />
            {tab !== "variables" && (
              <>
                <label className="inline-toggle">
                  <input
                    type="checkbox"
                    checked={changedOnly}
                    onChange={(event) => setChangedOnly(event.target.checked)}
                    disabled={splitDiff}
                  />
                  Changes only
                </label>
                <label className="inline-toggle">
                  <input
                    type="checkbox"
                    checked={splitDiff}
                    onChange={(event) => setSplitDiff(event.target.checked)}
                  />
                  Side by side
                </label>
              </>
            )}
            {tab === "variables" && (
              <label className="inline-toggle">
                <input
                  type="checkbox"
                  checked={variablesChangedOnly}
                  onChange={(event) => setVariablesChangedOnly(event.target.checked)}
                />
                Changed only
              </label>
            )}
          </div>

          {tab === "output" && (
            <DiffView
              lines={comparison.stdout}
              changedOnly={splitDiff ? false : changedOnly}
              split={splitDiff}
              emptyMessage="The two runs produced identical stdout."
            />
          )}
          {tab === "errors" && (
            <DiffView
              lines={comparison.stderr}
              changedOnly={splitDiff ? false : changedOnly}
              split={splitDiff}
              emptyMessage="Neither run wrote to stderr."
            />
          )}
          {tab === "variables" && (
            <div className="variable-diff">
              <div className="variable-diff-head">
                <span>Variable</span>
                <span>Baseline</span>
                <span>Experiment</span>
                <span>Status</span>
              </div>
              {visibleVariables.length === 0 && (
                <EmptyState
                  compact
                  title="No variable differences"
                  description={
                    comparison.variables.length === 0
                      ? "One of the runs may not have recorded a trace."
                      : "Both runs ended with identical variable values. Untick “Changed only” to see all variables."
                  }
                />
              )}
              {visibleVariables.map((variable) => (
                <div key={variable.name} className={`variable-diff-row status-${variable.status}`}>
                  <span className="variable-diff-name">{variable.name}</span>
                  <span className="variable-diff-value" title={variable.baselineValue ?? ""}>
                    {variable.baselineValue ?? <span className="muted">—</span>}
                    {variable.baselineType && (
                      <em className="variable-diff-type">{variable.baselineType}</em>
                    )}
                  </span>
                  <span className="variable-diff-value" title={variable.experimentValue ?? ""}>
                    {variable.experimentValue ?? <span className="muted">—</span>}
                    {variable.experimentType && (
                      <em className="variable-diff-type">{variable.experimentType}</em>
                    )}
                  </span>
                  <span>
                    <Badge
                      tone={
                        variable.status === "same"
                          ? "neutral"
                          : variable.status === "changed"
                            ? "warning"
                            : variable.status === "added"
                              ? "success"
                              : "danger"
                      }
                    >
                      {variable.status}
                    </Badge>
                  </span>
                </div>
              ))}
            </div>
          )}
        </div>
      )}
    </div>
  );
}

function MetricCard({
  icon,
  label,
  baseline,
  experiment,
  delta,
}: {
  icon: React.ReactNode;
  label: string;
  baseline: React.ReactNode;
  experiment: React.ReactNode;
  delta: string | null;
}) {
  return (
    <div className="metric-card">
      <div className="metric-card-head">
        {icon}
        <span>{label}</span>
        {delta && <span className={`metric-delta${delta.startsWith("-") ? " down" : " up"}`}>{delta}</span>}
      </div>
      <div className="metric-values">
        <div>
          <span className="metric-caption">Baseline</span>
          <span className="metric-value">{baseline}</span>
        </div>
        <ArrowRightIcon size={12} />
        <div>
          <span className="metric-caption">Experiment</span>
          <span className="metric-value">{experiment}</span>
        </div>
      </div>
    </div>
  );
}

function DiffView({
  lines,
  changedOnly,
  split,
  emptyMessage,
}: {
  lines: DiffLine[];
  changedOnly: boolean;
  split?: boolean;
  emptyMessage: string;
}) {
  const sideBySide = useMemo(() => {
    if (!split) return null;
    return {
      baseline: lines
        .filter((line) => line.kind !== "add")
        .slice(0, 2500)
        .map((line) => ({ number: line.baselineLine, text: line.text, changed: line.kind === "remove" })),
      experiment: lines
        .filter((line) => line.kind !== "remove")
        .slice(0, 2500)
        .map((line) => ({ number: line.experimentLine, text: line.text, changed: line.kind === "add" })),
    };
  }, [lines, split]);

  const displayed = useMemo(() => {
    if (!changedOnly) {
      return lines.slice(0, 2500).map((line, index) => ({ line, index }));
    }
    const keep = new Set<number>();
    lines.forEach((line, index) => {
      if (line.kind !== "same") {
        for (let offset = -2; offset <= 2; offset += 1) {
          const target = index + offset;
          if (target >= 0 && target < lines.length) keep.add(target);
        }
      }
    });
    return [...keep]
      .sort((left, right) => left - right)
      .slice(0, 2500)
      .map((index) => ({ line: lines[index]!, index, gap: false }));
  }, [lines, changedOnly]);

  const changedCount = lines.filter((line) => line.kind !== "same").length;

  if (lines.length === 0) {
    return <EmptyState compact title={emptyMessage} />;
  }

  if (changedCount === 0) {
    return <EmptyState compact title={emptyMessage} />;
  }

  if (sideBySide) {
    return (
      <div className="diff-view">
        <div className="diff-summary">
          {changedCount} changed {changedCount === 1 ? "line" : "lines"} · side-by-side view
        </div>
        <div className="diff-split">
          <div className="diff-side">
            <div className="diff-side-head">Baseline</div>
            {sideBySide.baseline.map((line, index) => (
              <div key={`a-${index}`} className={`diff-side-row${line.changed ? " remove" : ""}`}>
                <span className="diff-gutter">{line.number ?? ""}</span>
                <span className="diff-text">{line.text || " "}</span>
              </div>
            ))}
          </div>
          <div className="diff-side">
            <div className="diff-side-head">Experiment</div>
            {sideBySide.experiment.map((line, index) => (
              <div key={`b-${index}`} className={`diff-side-row${line.changed ? " add" : ""}`}>
                <span className="diff-gutter">{line.number ?? ""}</span>
                <span className="diff-text">{line.text || " "}</span>
              </div>
            ))}
          </div>
        </div>
      </div>
    );
  }

  return (
    <div className="diff-view">
      <div className="diff-summary">
        {changedCount} changed {changedCount === 1 ? "line" : "lines"}
        {lines.length > 2500 && " · truncated for display"}
      </div>
      <div className="diff-body">
        {displayed.map(({ line, index }, displayIndex) => {
          const previous = displayed[displayIndex - 1];
          const gap = previous ? index - previous.index > 1 : false;
          return (
            <div key={`${index}-${line.kind}`}>
              {gap && (
                <div className="diff-gap">
                  ⋯ {index - previous!.index - 1} unchanged{" "}
                  {index - previous!.index - 1 === 1 ? "line" : "lines"}
                </div>
              )}
              <div className={`diff-row diff-${line.kind}`}>
                <span className="diff-gutter">{line.baselineLine ?? ""}</span>
                <span className="diff-gutter">{line.experimentLine ?? ""}</span>
                <span className="diff-sign">
                  {line.kind === "add" ? "+" : line.kind === "remove" ? "−" : " "}
                </span>
                <span className="diff-text">{line.text || " "}</span>
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}
