import { describe, expect, it } from "vitest";
import {
  argsToString,
  basename,
  clip,
  formatBytes,
  formatDeltaPercent,
  formatDuration,
  normalizePath,
  relativePath,
  splitArgs,
  truncateMiddle,
} from "./format";

describe("formatDuration", () => {
  it("formats sub-second and second durations", () => {
    expect(formatDuration(null)).toBe("—");
    expect(formatDuration(0)).toBe("<1 ms");
    expect(formatDuration(12)).toBe("12 ms");
    expect(formatDuration(1500)).toBe("1.50 s");
    expect(formatDuration(62_000)).toBe("1m 2s");
    // Rounding must carry into minutes instead of yielding "1m 60s".
    expect(formatDuration(119_999)).toBe("2m 0s");
    expect(formatDuration(60_400)).toBe("1m 0s");
  });
});

describe("formatBytes", () => {
  it("uses binary units", () => {
    expect(formatBytes(512)).toBe("512 B");
    expect(formatBytes(2048)).toBe("2.00 KB");
    expect(formatBytes(5 * 1024 * 1024)).toBe("5.00 MB");
  });
});

describe("paths", () => {
  it("normalizes separators", () => {
    expect(normalizePath("a\\b\\")).toBe("a/b");
    expect(basename("a/b/c.py")).toBe("c.py");
    expect(basename("c.py")).toBe("c.py");
  });

  it("relativizes backend paths", () => {
    expect(relativePath("/work/demo/pkg/a.py", "/work/demo/")).toBe("pkg/a.py");
    expect(relativePath("/work/demo/main.py", "/work/demo")).toBe("main.py");
    expect(relativePath("/elsewhere/a.py", "/work/demo")).toBe("/elsewhere/a.py");
    expect(relativePath("/work/demo2/a.py", "/work/demo")).toBe("/work/demo2/a.py");
  });
});

describe("argument parsing", () => {
  it("round-trips quoted arguments", () => {
    const args = splitArgs('--name "Jane Doe" --count 2 \'x y\'');
    expect(args).toEqual(["--name", "Jane Doe", "--count", "2", "x y"]);
    expect(splitArgs(argsToString(args))).toEqual(args);
  });

  it("handles escapes and empty input", () => {
    expect(splitArgs("")).toEqual([]);
    expect(splitArgs("a\\ b")).toEqual(["a b"]);
    expect(splitArgs('""')).toEqual([""]);
  });
});

describe("misc formatting", () => {
  it("truncates in the middle", () => {
    expect(truncateMiddle("abcdefghij", 6)).toBe("ab…hij");
    expect(truncateMiddle("abc", 6)).toBe("abc");
    expect(clip("  a\n b   c ")).toBe("a b c");
  });

  it("computes deltas", () => {
    expect(formatDeltaPercent(100, 120)).toBe("+20.0%");
    expect(formatDeltaPercent(100, 80)).toBe("-20.0%");
    expect(formatDeltaPercent(0, 10)).toBeNull();
    expect(formatDeltaPercent(null, 10)).toBeNull();
  });
});
