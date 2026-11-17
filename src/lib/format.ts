/** Small formatting and parsing helpers shared across the UI. */

export function formatDuration(ms: number | null | undefined): string {
  if (ms === null || ms === undefined || Number.isNaN(ms)) return "—";
  if (ms < 1) return "<1 ms";
  if (ms < 1000) return `${Math.round(ms)} ms`;
  if (ms < 60_000) return `${(ms / 1000).toFixed(ms < 10_000 ? 2 : 1)} s`;
  const totalSeconds = Math.round(ms / 1000);
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = totalSeconds % 60;
  return `${minutes}m ${seconds}s`;
}

export function formatBytes(bytes: number | null | undefined): string {
  if (bytes === null || bytes === undefined || Number.isNaN(bytes)) return "—";
  if (bytes < 1024) return `${bytes} B`;
  const units = ["KB", "MB", "GB", "TB"];
  let value = bytes / 1024;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  const digits = value >= 100 ? 0 : value >= 10 ? 1 : 2;
  return `${value.toFixed(digits)} ${units[unit]}`;
}

export function formatClock(timestampMs: number): string {
  const date = new Date(timestampMs);
  const pad = (value: number) => String(value).padStart(2, "0");
  return `${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`;
}

export function formatShortDate(timestampMs: number): string {
  const date = new Date(timestampMs);
  return date.toLocaleDateString(undefined, {
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

export function relativeTime(timestampMs: number, now = Date.now()): string {
  const delta = Math.max(0, now - timestampMs);
  const minutes = Math.floor(delta / 60_000);
  if (minutes < 1) return "just now";
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h ago`;
  const days = Math.floor(hours / 24);
  if (days < 30) return `${days}d ago`;
  return formatShortDate(timestampMs);
}

export function basename(path: string): string {
  const normalized = path.replace(/\\/g, "/");
  const index = normalized.lastIndexOf("/");
  return index === -1 ? normalized : normalized.slice(index + 1);
}

export function dirname(path: string): string {
  const normalized = path.replace(/\\/g, "/");
  const index = normalized.lastIndexOf("/");
  return index === -1 ? "" : normalized.slice(0, index);
}

export function normalizePath(path: string): string {
  return path.replace(/\\/g, "/").replace(/\/+$/, "");
}

/** Convert an absolute path emitted by the backend into a project-relative path. */
export function relativePath(file: string, root: string): string {
  const normalizedFile = normalizePath(file);
  const normalizedRoot = normalizePath(root);
  // Require a directory boundary so "/app2/a.py" is not shortened for "/app".
  if (
    !normalizedFile.startsWith(normalizedRoot) ||
    (normalizedFile.length > normalizedRoot.length && normalizedFile[normalizedRoot.length] !== "/")
  ) {
    return normalizedFile;
  }
  const rest = normalizedFile.slice(normalizedRoot.length).replace(/^\/+/, "");
  return rest || basename(normalizedFile);
}

export function truncateMiddle(text: string, max: number): string {
  if (text.length <= max) return text;
  if (max <= 3) return text.slice(0, max);
  const keep = Math.floor((max - 1) / 2);
  return `${text.slice(0, keep)}…${text.slice(text.length - (max - keep - 1))}`;
}

/** Tokenize a command-line style argument string, honoring quotes and escapes. */
export function splitArgs(input: string): string[] {
  const args: string[] = [];
  let current = "";
  let quote: '"' | "'" | null = null;
  let escaping = false;
  let started = false;
  for (const character of input) {
    if (escaping) {
      current += character;
      escaping = false;
      started = true;
      continue;
    }
    if (character === "\\" && quote !== "'") {
      escaping = true;
      started = true;
      continue;
    }
    if (quote) {
      if (character === quote) {
        quote = null;
      } else {
        current += character;
      }
      continue;
    }
    if (character === '"' || character === "'") {
      quote = character;
      started = true;
      continue;
    }
    if (/\s/.test(character)) {
      if (started) {
        args.push(current);
        current = "";
        started = false;
      }
      continue;
    }
    current += character;
    started = true;
  }
  if (started) args.push(current);
  return args;
}

export function argsToString(args: string[]): string {
  return args
    .map((arg) => (/\s|"/.test(arg) ? `"${arg.replace(/"/g, '\\"')}"` : arg))
    .join(" ");
}

export function pluralize(count: number, singular: string, plural?: string): string {
  return count === 1 ? singular : (plural ?? `${singular}s`);
}

export function statusLabel(status: string): string {
  switch (status) {
    case "running":
      return "Running";
    case "ok":
      return "Succeeded";
    case "error":
      return "Failed";
    case "timeout":
      return "Timed out";
    case "cancelled":
      return "Cancelled";
    case "crashed":
      return "Crashed";
    default:
      return status;
  }
}

export function kindLabel(kind: string): string {
  switch (kind) {
    case "var":
      return "Variable";
    case "call":
      return "Call";
    case "return":
      return "Return";
    case "line":
      return "Line";
    case "exception":
      return "Exception";
    case "session_start":
      return "Start";
    case "session_end":
      return "End";
    case "truncated":
      return "Truncated";
    default:
      return kind;
  }
}

export function isNoisyType(vtype: string): boolean {
  return [
    "module",
    "function",
    "builtin_function_or_method",
    "method",
    "type",
    "classmethod",
    "staticmethod",
  ].includes(vtype);
}

export function formatDeltaPercent(baseline: number | null, experiment: number | null): string | null {
  if (baseline === null || experiment === null || baseline === 0) return null;
  const delta = ((experiment - baseline) / baseline) * 100;
  const sign = delta > 0 ? "+" : "";
  return `${sign}${delta.toFixed(1)}%`;
}

export function clip(value: string, max = 120): string {
  const singleLine = value.replace(/\s+/g, " ").trim();
  return truncateMiddle(singleLine, max);
}
