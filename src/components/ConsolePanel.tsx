import { useEffect, useRef, useState } from "react";
import { useStore } from "../store";
import { formatBytes, formatDuration, statusLabel } from "../lib/format";
import { IconButton, PanelHeader, StatusDot } from "./ui";
import { AlertIcon, CloseIcon, TerminalIcon } from "./Icons";

type StreamTab = "stdout" | "stderr";

export function ConsolePanel() {
  const session = useStore((state) => state.activeSession);
  const output = useStore((state) => state.output);
  const liveStdout = useStore((state) => state.liveStdout);
  const liveStderr = useStore((state) => state.liveStderr);
  const running = session?.status === "running";
  const [tab, setTab] = useState<StreamTab>("stdout");
  const [autoScroll, setAutoScroll] = useState(true);
  const [wrap, setWrap] = useState(false);
  const [offsets, setOffsets] = useState({ stdout: 0, stderr: 0 });
  const bodyRef = useRef<HTMLPreElement>(null);

  useEffect(() => {
    setOffsets({ stdout: 0, stderr: 0 });
    setTab("stdout");
  }, [session?.id]);

  const stdoutRaw = running ? liveStdout : output?.stdout ?? session?.stdoutPreview ?? "";
  const stderrRaw = running ? liveStderr : output?.stderr ?? session?.stderrPreview ?? "";
  const stdout = stdoutRaw.slice(offsets.stdout);
  const stderr = stderrRaw.slice(offsets.stderr);
  const text = tab === "stdout" ? stdout : stderr;
  const stdoutSize = running ? stdoutRaw.length : (session?.stdoutBytes ?? stdoutRaw.length);
  const stderrSize = running ? stderrRaw.length : (session?.stderrBytes ?? stderrRaw.length);
  const truncated =
    !running &&
    (output
      ? tab === "stdout"
        ? output.stdoutTruncated
        : output.stderrTruncated
      : (tab === "stdout" ? (session?.stdoutBytes ?? 0) : (session?.stderrBytes ?? 0)) >=
        2_900_000);

  useEffect(() => {
    if (!autoScroll) return;
    const node = bodyRef.current;
    if (!node) return;
    node.scrollTop = node.scrollHeight;
  }, [text, autoScroll, tab]);

  const clearView = () => {
    setOffsets({
      stdout: tab === "stdout" ? stdoutRaw.length : offsets.stdout,
      stderr: tab === "stderr" ? stderrRaw.length : offsets.stderr,
    });
  };

  return (
    <div className="console">
      <PanelHeader
        title="Console"
        icon={<TerminalIcon size={13} />}
        subtitle={session ? session.command : undefined}
        actions={
          <>
            {session && (
              <span className="console-status">
                <StatusDot status={session.status} />
                <span>{statusLabel(session.status)}</span>
                {session.exitCode !== null && <span className="muted">exit {session.exitCode}</span>}
                {session.durationMs !== null && (
                  <span className="muted">{formatDuration(session.durationMs)}</span>
                )}
              </span>
            )}
            <button
              type="button"
              className={`mini-link${wrap ? " active" : ""}`}
              onClick={() => setWrap((value) => !value)}
            >
              Wrap
            </button>
            <button
              type="button"
              className={`mini-link${autoScroll ? " active" : ""}`}
              onClick={() => setAutoScroll((value) => !value)}
            >
              Auto-scroll
            </button>
            <IconButton title="Clear this view" onClick={clearView}>
              <CloseIcon size={13} />
            </IconButton>
          </>
        }
      />

      <div className="console-tabs">
        <button
          type="button"
          className={`console-tab${tab === "stdout" ? " active" : ""}`}
          onClick={() => setTab("stdout")}
        >
          stdout
          <span className="tab-count">{formatBytes(stdoutSize)}</span>
        </button>
        <button
          type="button"
          className={`console-tab${tab === "stderr" ? " active" : ""}`}
          onClick={() => setTab("stderr")}
        >
          stderr
          {stderrRaw.length > 0 && tab !== "stderr" && <span className="tab-dot danger" />}
          <span className="tab-count">{formatBytes(stderrSize)}</span>
        </button>
        <div className="console-tabs-spacer" />
        {running && (
          <span className="console-live">
            <span className="status-dot status-accent pulsing" />
            streaming
          </span>
        )}
        {truncated && (
          <span className="console-live warning">
            <AlertIcon size={11} /> {tab} truncated
          </span>
        )}
        {session?.error && (
          <span className="console-error" title={session.error}>
            {session.error}
          </span>
        )}
      </div>

      <pre
        ref={bodyRef}
        className={`console-body${wrap ? " wrap" : ""}`}
        aria-label={`${tab} output`}
      >
        {text.length === 0 ? (
          <span className="console-empty">
            {session
              ? running
                ? "Waiting for output…"
                : `No ${tab} output was captured.`
              : "Run the project to see console output."}
          </span>
        ) : (
          text
        )}
        {running && <span className="console-caret">▍</span>}
      </pre>
    </div>
  );
}
