import { describe, expect, it } from "vitest";
import { rankQuickOpenFiles } from "./quick-open";
import type { FileEntry } from "../types";

const files: FileEntry[] = [
  { path: "src/pricing.py", name: "pricing.py", isDir: false, isPython: true, size: 10 },
  { path: "src/discounts.py", name: "discounts.py", isDir: false, isPython: true, size: 10 },
  { path: "src", name: "src", isDir: true, isPython: false, size: 0 },
  { path: "README.md", name: "README.md", isDir: false, isPython: false, size: 10 },
];

describe("rankQuickOpenFiles", () => {
  it("matches all query terms against file paths and excludes directories", () => {
    expect(rankQuickOpenFiles(files, "src pric", [], null).map((file) => file.path)).toEqual([
      "src/pricing.py",
    ]);
  });

  it("shows the active and most recently opened files first when the query is empty", () => {
    expect(
      rankQuickOpenFiles(files, "", ["src/pricing.py", "src/discounts.py"], "src/pricing.py")
        .map((file) => file.path),
    ).toEqual(["src/pricing.py", "src/discounts.py", "README.md"]);
  });
});
