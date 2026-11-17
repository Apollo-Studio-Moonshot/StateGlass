import { useEffect, useMemo, useState } from "react";
import { useStore } from "../store";
import type { TraceEvent, VariableSnapshot } from "../types";
import {
  clip,
  isNoisyType,
  relativePath,
} from "../lib/format";
import { Badge, EmptyState, PanelHeader, Spinner } from "./ui";
import {
  ArrowRightIcon,
  FlowIcon,
  PinIcon,
  SearchIcon,
  VariableIcon,
} from "./Icons";

export function VariableInspector() {
  const session = useStore((state) => state.activeSession);
  const workspace = useStore((state) => state.workspace);
  const cursorSeq = useStore((state) => state.cursorSeq);
  const variables = useStore((state) => state.variables);
  const selectedVariable = useStore((state) => state.selectedVariable);
  const watchlist = useStore((state) => state.watchlist);
  const toggleWatch = useStore((state) => state.toggleWatch);
  const selectVariable = useStore((state) => state.selectVariable);
  const history = useStore((state) => state.history);
  const loadVariables = useStore((state) => state.loadVariables);
  const loadFlow = useStore((state) => state.loadFlow);
  const setCenterTab = useStore((state) => state.setCenterTab);
  const setCursor = useStore((state) => state.setCursor);
  const revealLocation = useStore((state) => state.revealLocation);
  const revision = useStore((state) => state.traceRevision);

  const [query, setQuery] = useState("");
  const [hideNoisy, setHideNoisy] = useState(true);
  const [refreshing, setRefreshing] = useState(false);

  useEffect(() => {
    if (session?.status !== "running") return;
    const timer = window.setTimeout(() => {
      setRefreshing(true);
      void loadVariables(cursorSeq).finally(() => setRefreshing(false));
    }, 700);
    return () => window.clearTimeout(timer);
  }, [revision, session?.status, cursorSeq, loadVariables]);

  const filtered = useMemo(() => {
    const needle = query.trim().toLowerCase();
    return variables.filter((variable) => {
      if (hideNoisy && (isNoisyType(variable.vtype) || variable.name === "self")) return false;
      if (!needle) return true;
      return `${variable.name} ${variable.value} ${variable.vtype} ${variable.func ?? ""}`
        .toLowerCase()
        .includes(needle);
    });
  }, [variables, query, hideNoisy]);

  const root = workspace?.root ?? session?.cwd ?? "";

  const openFlow = () => {
    if (!selectedVariable) return;
    setCenterTab("flow");
    void loadFlow();
  };

  return (
    <div className="inspector">
      <PanelHeader
        title="Variables"
        icon={<VariableIcon size={13} />}
        count={filtered.length !== variables.length ? `${filtered.length}/${variables.length}` : variables.length}
        subtitle={cursorSeq ? `at #${cursorSeq}` : "latest state"}
        actions={
          <>
            {refreshing && <Spinner size={12} />}
            <button
              type="button"
              className={`mini-link${hideNoisy ? " active" : ""}`}
              onClick={() => setHideNoisy((value) => !value)}
              title="Hide modules, functions and types"
            >
              {hideNoisy ? "Locals only" : "All names"}
            </button>
          </>
        }
      />

      <div className="inspector-search">
        <SearchIcon size={13} />
        <input
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          placeholder="Filter variables…"
          spellCheck={false}
          aria-label="Filter variables"
        />
      </div>

      {session && watchlist.length > 0 && (
        <div className="watch-list" role="group" aria-label="Pinned variables">
          <div className="watch-head">
            <span>Pinned</span>
            <span>{watchlist.length}</span>
          </div>
          {watchlist.map((name) => {
            const variable = variables.find((candidate) => candidate.name === name);
            return (
              <div
                key={name}
                className={`variable-row watch-row${
                  name === selectedVariable ? " selected" : ""
                }`}
                role="row"
                onClick={() => void selectVariable(name)}
                title={
                  variable
                    ? `${name} = ${variable.value}`
                    : `${name} is not in scope at this point`
                }
              >
                <span className="variable-name">
                  <PinIcon size={10} className="pin-glyph" />
                  {name}
                </span>
                <span className={`variable-value${variable ? "" : " watch-missing"}`}>
                  {variable ? clip(variable.value, 90) : "not in scope"}
                </span>
                <span className="variable-type">{variable?.vtype ?? "—"}</span>
                <div className="variable-meta">
                  <button
                    type="button"
                    className="variable-pin active"
                    title="Unpin variable"
                    onClick={(event) => {
                      event.stopPropagation();
                      toggleWatch(name);
                    }}
                  >
                    <PinIcon size={11} />
                  </button>
                </div>
              </div>
            );
          })}
        </div>
      )}

      {!session ? (
        <EmptyState
          compact
          icon={<VariableIcon size={22} />}
          title="No variables yet"
          description="Run the project with tracing to inspect variable values at any point in time."
        />
      ) : filtered.length === 0 ? (
        <EmptyState
          compact
          title={variables.length === 0 ? "No snapshot at this point" : "No matching variables"}
          description={
            variables.length === 0
              ? "Move the timeline cursor to a variable change, or run again with tracing enabled."
              : "Clear the filter or show all names."
          }
        />
      ) : (
        <div className="variable-table" role="table" aria-label="Variables at the selected point">
          <div className="variable-head" role="row">
            <span>Name</span>
            <span>Value</span>
            <span>Type</span>
          </div>
          {filtered.map((variable) => (
            <VariableRow
              key={variable.name}
              variable={variable}
              selected={variable.name === selectedVariable}
              changedHere={cursorSeq !== null && variable.seq === cursorSeq}
              pinned={watchlist.includes(variable.name)}
              root={root}
              onClick={() => void selectVariable(variable.name)}
              onTogglePin={() => toggleWatch(variable.name)}
              onReveal={() => void revealLocation(variable.file, variable.line)}
            />
          ))}
        </div>
      )}

      {selectedVariable && (
        <div className="history">
          <div className="history-header">
            <div>
              <span className="history-title">{selectedVariable}</span>
              <Badge tone="neutral">{history.length} changes</Badge>
            </div>
            <button type="button" className="mini-link" onClick={openFlow} title="Open data-flow graph">
              <FlowIcon size={12} /> Data flow
            </button>
          </div>

          {history.length === 0 ? (
            <div className="history-empty">No recorded changes for this name.</div>
          ) : (
            <div className="history-list">
              {history.map((event) => (
                <HistoryRow
                  key={event.id}
                  event={event}
                  selected={event.seq === cursorSeq}
                  onClick={() => void setCursor(event.seq)}
                  onReveal={() => void revealLocation(event.file, event.line)}
                />
              ))}
            </div>
          )}
        </div>
      )}
    </div>
  );
}

function VariableRow({
  variable,
  selected,
  changedHere,
  pinned,
  root,
  onClick,
  onTogglePin,
  onReveal,
}: {
  variable: VariableSnapshot;
  selected: boolean;
  changedHere: boolean;
  pinned: boolean;
  root: string;
  onClick: () => void;
  onTogglePin: () => void;
  onReveal: () => void;
}) {
  return (
    <div
      className={`variable-row${selected ? " selected" : ""}`}
      role="row"
      onClick={onClick}
      title={`${variable.name}\n${variable.value}\n${variable.func ?? ""} ${variable.file ?? ""}:${variable.line ?? ""}`}
    >
      <span className="variable-name">
        {changedHere && <span className="changed-dot" title="Changed at this point" />}
        {variable.name}
      </span>
      <span className="variable-value" title={variable.value}>
        {clip(variable.value, 90)}
      </span>
      <span className="variable-type">{variable.vtype}</span>
      <div className="variable-meta">
        <button
          type="button"
          className={`variable-pin${pinned ? " active" : ""}`}
          title={pinned ? "Unpin variable" : "Pin variable"}
          aria-pressed={pinned}
          onClick={(event) => {
            event.stopPropagation();
            onTogglePin();
          }}
        >
          <PinIcon size={11} />
        </button>
        <span className="variable-location">{variable.func ?? ""}</span>
        {variable.file && (
          <button
            type="button"
            className="row-jump"
            title={`Open ${relativePath(variable.file, root)}:${variable.line ?? ""}`}
            onClick={(event) => {
              event.stopPropagation();
              onReveal();
            }}
          >
            L{variable.line}
            <ArrowRightIcon size={11} />
          </button>
        )}
      </div>
    </div>
  );
}

function HistoryRow({
  event,
  selected,
  onClick,
  onReveal,
}: {
  event: TraceEvent;
  selected: boolean;
  onClick: () => void;
  onReveal: () => void;
}) {
  return (
    <div
      className={`history-row${selected ? " selected" : ""}`}
      onClick={onClick}
      title={`#${event.seq} · ${event.file ?? ""}:${event.line ?? ""}`}
    >
      <span className="history-index">#{event.seq}</span>
      <span className="history-value" title={event.value ?? ""}>
        {clip(event.value ?? "", 48)}
      </span>
      <span className="history-location">
        {event.func ?? ""}
        {event.line ? `:${event.line}` : ""}
      </span>
      <button
        type="button"
        className="row-jump"
        title="Open source line"
        onClick={(clickEvent) => {
          clickEvent.stopPropagation();
          onReveal();
        }}
      >
        <ArrowRightIcon size={11} />
      </button>
    </div>
  );
}
