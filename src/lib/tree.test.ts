import { describe, expect, it } from "vitest";
import type { FileEntry } from "../types";
import { buildFileTree, collectDirectoryPaths, filterTree, flattenTree, pythonFiles } from "./tree";

const entries: FileEntry[] = [
  { path: "pricing.py", name: "pricing.py", isDir: false, isPython: true, size: 10 },
  { path: "README.md", name: "README.md", isDir: false, isPython: false, size: 10 },
  { path: "pkg", name: "pkg", isDir: true, isPython: false, size: 0 },
  { path: "pkg/util.py", name: "util.py", isDir: false, isPython: true, size: 10 },
  { path: "pkg/deep", name: "deep", isDir: true, isPython: false, size: 0 },
  { path: "pkg/deep/helpers.py", name: "helpers.py", isDir: false, isPython: true, size: 10 },
];

describe("buildFileTree", () => {
  it("nests files and puts directories first", () => {
    const tree = buildFileTree(entries);
    expect(tree.map((node) => node.name)).toEqual(["pkg", "pricing.py", "README.md"]);
    const pkg = tree[0]!;
    expect(pkg.children.map((node) => node.name)).toEqual(["deep", "util.py"]);
    expect(pkg.children[1]!.file?.path).toBe("pkg/util.py");
  });

  it("creates implicit parents for orphan files", () => {
    const tree = buildFileTree([
      { path: "a/b/c.py", name: "c.py", isDir: false, isPython: true, size: 1 },
    ]);
    expect(tree[0]!.path).toBe("a");
    expect(tree[0]!.children[0]!.path).toBe("a/b");
    expect(tree[0]!.children[0]!.children[0]!.name).toBe("c.py");
  });

  it("flattens according to expanded directories", () => {
    const tree = buildFileTree(entries);
    const flat = flattenTree(tree, new Set(["pkg"]));
    expect(flat.map((row) => row.node.name)).toEqual(["pkg", "deep", "util.py", "pricing.py", "README.md"]);
  });

  it("collects directory paths and python files", () => {
    const tree = buildFileTree(entries);
    expect(collectDirectoryPaths(tree).sort()).toEqual(["pkg", "pkg/deep"]);
    expect(pythonFiles(tree).sort()).toEqual([
      "pkg/deep/helpers.py",
      "pkg/util.py",
      "pricing.py",
    ]);
  });
});

describe("filterTree", () => {
  it("keeps ancestors of matching files", () => {
    const tree = buildFileTree(entries);
    const filtered = filterTree(tree, "helpers");
    expect(filtered).toHaveLength(1);
    expect(filtered[0]!.name).toBe("pkg");
    expect(filtered[0]!.children[0]!.name).toBe("deep");
    expect(filtered[0]!.children[0]!.children[0]!.name).toBe("helpers.py");
  });

  it("matches directory names", () => {
    const tree = buildFileTree(entries);
    const filtered = filterTree(tree, "pkg");
    expect(filtered[0]!.name).toBe("pkg");
    expect(filtered[0]!.children).toHaveLength(2);
  });

  it("returns everything for an empty query", () => {
    const tree = buildFileTree(entries);
    expect(filterTree(tree, "  ")).toBe(tree);
  });
});
