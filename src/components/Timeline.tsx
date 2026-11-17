import { useEffect, useMemo, useRef, useState } from "react";
import { api, errorMessage } from "../api";
import { useStore } from "../store";
import type { TraceEvent, TraceStats } from "../types";
import {
  clip,
  formatClock,
  formatDuration,
  kindLabel,
  relativePath,
} from "../lib/format";
import { EmptyState, IconButton, PanelHeader, Spinner } from "./ui";
import {
  ArrowRightIcon,
  ChevronRightIcon,
  ClockIcon,
  PlayIcon,
  SearchIcon,
} from "./Icons";

const KINDS = [
  { value: "var", label: "Variables" },
  { value: "call", label: "Calls" },
  { value: "return", label: "Returns" },
  { value: "line", label: "Lines" },
  { value: "exception", label: "Errors" },
] as const;

const META_KINDS = ["session_start", "session_end", "truncated"];
const DEFAULT_KINDS = ["var", "call", "exception", "session_start", "session_end", "truncated"];

export function Timeline() {
  const session = useStore((state) => state.activeSession);
  const workspace = useStore((state) => state.workspace);
  const cursorSeq = useStore((state) => state.cursorSeq);
  const setCursor = useStore((state) => state.setCursor);
  const revealLocation = useStore((state) => state.revealLocation);
  const revision = useStore((state) => state.traceRevision);

  const [selectedKinds, setSelectedKinds] = useState<Set<string>>(new Set(DEFAULT_KINDS));
  const [search, setSearch] = useState("");
  const [events, setEvents] = useState<TraceEvent[]>([]);
  const [total, setTotal] = useState(0);
  const [stats, setStats] = useState<TraceStats | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [showAll, setShowAll] = useState(false);
  const [pageLimited, setPageLimited] = useState(false);
  const rowRefs = useRef(new Map<number, HTMLDivElement>());
  const stripRef = useRef<HTMLDivElement>(null);

  const kindsKey = useMemo(() => [...selectedKinds].sort().join(","), [selectedKinds]);

  useEffect(() => {
    setShowAll(false);
    setEvents([]);
    setTotal(0);
    setPageLimited(false);
    setStats(null);
  }, [session?.id]);

  useEffect(() => {
    if (!session) {
      setStats(null);
      return;
    }
    let cancelled = false;
    const timer = window.setTimeout(
      () => {
        void api
          .traceStats(session.id)
          .then((value) => {
            if (!cancelled) setStats(value);
          })
          .catch(() => undefined);
      },
      session.status === "running" ? 650 : 60,
    );
    return () => {
      cancelled = true;
      window.clearTimeout(timer);
    };
  }, [session?.id, session?.status, revision]);

  useEffect(() => {
    if (!session) {
      setEvents([]);
      setTotal(0);
      setPageLimited(false);
      return;
    }
    let cancelled = false;
    setLoading(true);
    setError(null);
    setPageLimited(false);
    const timer = window.setTimeout(() => {
      void api
        .listTraceEvents(session.id, { kinds: [...selectedKinds], limit: 5000, tail: true })
        .then((page) => {
          if (cancelled) return;
          setEvents(page.events);
          setTotal(page.total);
          setPageLimited(page.returned >= 5000);
          setLoading(false);
        })
        .catch((cause) => {
          if (cancelled) return;
          setError(errorMessage(cause));
          setLoading(false);
        });
    }, session.status === "running" ? 420 : 60);
    return () => {
      cancelled = true;
      window.clearTimeout(timer);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [session?.id, session?.status, kindsKey, revision]);

  const filtered = useMemo(() => {
    const needle = search.trim().toLowerCase();
    if (!needle) return events;
    return events.filter((event) =>
      [event.name, event.value, event.func, event.file, event.line?.toString(), event.vtype]
        .filter(Boolean)
        .join(" ")
        .toLowerCase()
        .includes(needle),
    );
  }, [events, search]);

  const maxSeq = useMemo(() => {
    // `total` covers every stored event, including kinds hidden by the chips,
    // so the strip keeps a stable scale while filters change.
    if (total > 0) return Math.max(1, total);
    if (events.length > 0) return Math.max(1, events[events.length - 1]!.seq);
    return 1;
  }, [events, total]);

  const lastSeq = events.length > 0 ? events[events.length - 1]!.seq : null;
  const lastTime = lastSeq === null ? null : selectedTime(events, lastSeq);
  const selectedSeq = cursorSeq ?? lastSeq;
  const cursorPercent = selectedSeq === null ? 0 : clampPercent((selectedSeq / maxSeq) * 100);
  const cursorTime = selectedSeq === null ? null : selectedTime(events, selectedSeq);

  const ticks = useMemo(() => {
    if (filtered.length === 0) return [];
    const step = Math.max(1, Math.ceil(filtered.length / 420));
    const sampled = filtered.filter((_, index) => index % step === 0);
    return sampled;
  }, [filtered]);

  useEffect(() => {
    if (selectedSeq === null) return;
    const node = rowRefs.current.get(selectedSeq);
    node?.scrollIntoView({ block: "nearest" });
  }, [selectedSeq]);

  const variableEvents = useMemo(() => filtered.filter((event) => event.kind === "var"), [filtered]);

  const stepVariable = (direction: 1 | -1) => {
    if (variableEvents.length === 0) return;
    const current = selectedSeq ?? 0;
    if (direction === 1) {
      const next = variableEvents.find((event) => event.seq > current);
      void setCursor(next?.seq ?? variableEvents[variableEvents.length - 1]!.seq);
    } else {
      const previous = [...variableEvents].reverse().find((event) => event.seq < current);
      void setCursor(previous?.seq ?? variableEvents[0]!.seq);
    }
  };

  const jumpToMatch = (direction: 1 | -1) => {
    if (filtered.length === 0) return;
    const current = selectedSeq ?? (direction === 1 ? 0 : Number.MAX_SAFE_INTEGER);
    const match =
      direction === 1
        ? filtered.find((event) => event.seq > current)
        : [...filtered].reverse().find((event) => event.seq < current);
    const target = match ?? (direction === 1 ? filtered[0]! : filtered[filtered.length - 1]!);
    void setCursor(target.seq);
  };

  const onStripClick = (event: React.MouseEvent<HTMLDivElement>) => {
    const element = stripRef.current;
    if (!element || events.length === 0) return;
    const rect = element.getBoundingClientRect();
    const ratio = Math.min(1, Math.max(0, (event.clientX - rect.left) / rect.width));
    const target = Math.round(ratio * maxSeq);
    const nearest = events.reduce((best, candidate) =>
      Math.abs(candidate.seq - target) < Math.abs(best.seq - target) ? candidate : best,
    );
    void setCursor(nearest.seq);
  };

  const root = workspace?.root ?? session?.cwd ?? "";
  const visible = showAll ? filtered : filtered.slice(-900);
  const hiddenBefore = showAll ? 0 : Math.max(0, filtered.length - 900);

  return (
    <div className="timeline">
      <PanelHeader
        title="Timeline"
        icon={<ClockIcon size={13} />}
        count={stats ? stats.total.toLocaleString() : session ? session.traceEventCount : undefined}
        actions={
          <>
            {loading && <Spinner size={12} />}
            <IconButton title="Previous variable change" onClick={() => stepVariable(-1)}>
              <ChevronRightIcon size={13} style={{ transform: "rotate(180deg)" }} />
            </IconButton>
            <IconButton title="Next variable change" onClick={() => stepVariable(1)}>
              <ChevronRightIcon size={13} />
            </IconButton>
            <button
              type="button"
              className={`mini-link${cursorSeq === null ? " active" : ""}`}
              onClick={() => void setCursor(null)}
              title="Show the latest state"
            >
              Latest
            </button>
          </>
        }
      />

      {!session ? (
        <EmptyState
          compact
          icon={<PlayIcon size={22} />}
          title="No execution selected"
          description="Run the project to record an execution, then scrub through its history here."
        />
      ) : (
        <>
          <div className="timeline-search">
            <SearchIcon size={13} />
            <input
              value={search}
              onChange={(event) => setSearch(event.target.value)}
              onKeyDown={(event) => {
                if (event.key !== "Enter") return;
                event.preventDefault();
                jumpToMatch(event.shiftKey ? -1 : 1);
              }}
              placeholder="Filter events… (Enter jumps to the next match)"
              spellCheck={false}
              aria-label="Filter trace events"
            />
            {events.length > 0 && (
              <span className="timeline-search-count">
                {filtered.length} / {events.length}
              </span>
            )}
          </div>

          <div className="timeline-chips">
            {KINDS.map((kind) => (
              <button
                type="button"
                key={kind.value}
                className={`chip${selectedKinds.has(kind.value) ? " active" : ""}`}
                onClick={() =>
                  setSelectedKinds((current) => {
                    const next = new Set(current);
                    if (next.has(kind.value)) next.delete(kind.value);
                    else next.add(kind.value);
                    for (const meta of META_KINDS) next.add(meta);
                    return next;
                  })
                }
              >
                {kind.label}
                {stats && (
                  <span className="chip-count">
                    {stats.kinds.find((entry) => entry.kind === kind.value)?.count ?? 0}
                  </span>
                )}
              </button>
            ))}
          </div>

          {events.length > 0 && (
            <div className="timeline-strip-wrap">
              <div
                ref={stripRef}
                className="timeline-strip"
                onClick={onStripClick}
                title="Click to jump to an execution event"
                role="slider"
                aria-label="Execution position"
                aria-valuemin={1}
                aria-valuemax={maxSeq}
                aria-valuenow={Math.min(maxSeq, Math.max(1, selectedSeq ?? maxSeq))}
                tabIndex={0}
                onKeyDown={(event) => {
                  if (event.key === "ArrowRight") {
                    event.preventDefault();
                    stepVariable(1);
                  } else if (event.key === "ArrowLeft") {
                    event.preventDefault();
                    stepVariable(-1);
                  }
                }}
              >
                {ticks.map((event) => (
                  <span
                    key={event.id}
                    className={`tick kind-${event.kind}`}
                    style={{ left: `${(event.seq / maxSeq) * 100}%`, height: tickHeight(event) }}
                    title={`${kindLabel(event.kind)} · ${event.func ?? ""} ${event.name ?? ""}`}
                  />
                ))}
                {selectedSeq !== null && (
                  <span className="timeline-cursor" style={{ left: `${cursorPercent}%` }}>
                    {cursorTime !== null && (
                      <span className="timeline-cursor-label">
                        {formatDuration(Math.max(0, cursorTime - session.startedAt))}
                      </span>
                    )}
                  </span>
                )}
              </div>
              <div className="timeline-axis">
                <span>0s</span>
                <span>
                  {formatDuration(
                    session.durationMs ??
                      Math.max(0, lastTime !== null ? lastTime - session.startedAt : 0),
                  )}
                </span>
              </div>
            </div>
          )}

          {error && <div className="inline-error">{error}</div>}

          <div className="timeline-list">
            {filtered.length === 0 && !loading && (
              <EmptyState
                compact
                title={
                  events.length === 0
                    ? session.status === "running"
                      ? "Waiting for trace events…"
                      : "No trace events captured"
                    : "No events match this filter"
                }
                description={
                  events.length === 0
                    ? session.status === "running"
                      ? "The instrumentation helper is starting up."
                      : "Tracing may be disabled for this run, or the program produced no events."
                    : "Adjust the event type chips or clear the search."
                }
              />
            )}

            {stats?.truncated && (
              <div className="timeline-note">
                This execution reached the trace event limit, so later events were not recorded.
              </div>
            )}

            {pageLimited && (
              <div className="timeline-note">
                Showing the latest {events.length.toLocaleString()} matching events. Narrow the
                kind filters to inspect earlier activity.
              </div>
            )}

            {hiddenBefore > 0 && (
              <div className="timeline-note">
                Showing the last 900 events ({hiddenBefore.toLocaleString()} earlier events
                hidden).{" "}
                <button type="button" className="mini-link" onClick={() => setShowAll(true)}>
                  Show all {filtered.length.toLocaleString()}
                </button>
              </div>
            )}

            {visible.map((event) => {
              const isSelected = event.seq === selectedSeq;
              return (
                <div
                  key={event.id}
                  ref={(node) => {
                    if (node) rowRefs.current.set(event.seq, node);
                    else rowRefs.current.delete(event.seq);
                  }}
                  className={`timeline-row kind-${event.kind}${isSelected ? " selected" : ""}`}
                  onClick={() => void setCursor(event.seq)}
                  onDoubleClick={() => void revealLocation(event.file, event.line)}
                  title={eventTooltip(event)}
                >
                  <span className="timeline-row-time">
                    {formatClock(event.ts)} · {formatOffset(event.ts, session.startedAt)}
                  </span>
                  <span className={`kind-badge kind-${event.kind}`}>{kindLabel(event.kind)}</span>
                  <span className="timeline-row-function">{event.func ?? "—"}</span>
                  <span className="timeline-row-detail">{eventDetail(event)}</span>
                  <span className="timeline-row-location">
                    {event.file ? `${relativePath(event.file, root)}:${event.line ?? ""}` : ""}
                  </span>
                  {event.file && event.line ? (
                    <button
                      type="button"
                      className="timeline-row-jump"
                      title="Open source line"
                      onClick={(clickEvent) => {
                        clickEvent.stopPropagation();
                        void revealLocation(event.file, event.line);
                      }}
                    >
                      <ArrowRightIcon size={12} />
                    </button>
                  ) : (
                    <span className="timeline-row-jump-placeholder" />
                  )}
                </div>
              );
            })}
          </div>
        </>
      )}
    </div>
  );
}

function selectedTime(events: TraceEvent[], seq: number): number | null {
  const event = events.find((candidate) => candidate.seq === seq);
  return event?.ts ?? null;
}

function clampPercent(value: number): number {
  return Number.isFinite(value) ? Math.min(100, Math.max(0, value)) : 0;
}

function formatOffset(timestamp: number, startedAt: number): string {
  return `+${formatDuration(Math.max(0, timestamp - startedAt))}`;
}

function tickHeight(event: TraceEvent): number {
  if (event.kind === "var") return 14;
  if (event.kind === "exception") return 16;
  if (event.kind === "call") return 10;
  if (event.kind === "session_start" || event.kind === "session_end") return 18;
  return 6;
}

function eventDetail(event: TraceEvent): string {
  switch (event.kind) {
    case "var":
      return `${event.name ?? "?"} = ${clip(event.value ?? "", 86)}`;
    case "call":
      return `${event.func ?? "?"}()`;
    case "return":
      return `${event.func ?? "?"} → ${clip(event.value ?? "None", 60)}`;
    case "exception":
      return `${event.vtype ?? "Exception"}: ${clip(event.value ?? "", 70)}`;
    case "session_start":
      return "execution started";
    case "session_end":
      return `execution finished${event.value ? `: ${event.value}` : ""}`;
    default:
      return clip(event.value ?? event.name ?? "", 90);
  }
}

function eventTooltip(event: TraceEvent): string {
  const lines = [
    `${kindLabel(event.kind)} #${event.seq}`,
    event.func ? `function: ${event.func}` : null,
    event.name ? `${event.name} = ${event.value ?? ""}` : null,
    event.file ? `${event.file}:${event.line ?? ""}` : null,
    event.vtype ? `type: ${event.vtype}` : null,
  ];
  return lines.filter(Boolean).join("\n");
}
