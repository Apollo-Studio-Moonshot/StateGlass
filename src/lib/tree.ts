/** Build and filter the project explorer tree from the backend's flat listing. */

import type { FileEntry } from "../types";

export interface TreeNode {
  name: string;
  path: string;
  isDir: boolean;
  file: FileEntry | null;
  children: TreeNode[];
}

function emptyNode(name: string, path: string, isDir: boolean): TreeNode {
  return { name, path, isDir, file: null, children: [] };
}

export function buildFileTree(entries: FileEntry[]): TreeNode[] {
  const root: TreeNode = emptyNode("", "", true);
  const byPath = new Map<string, TreeNode>([["", root]]);

  const ensureDir = (path: string): TreeNode => {
    const existing = byPath.get(path);
    if (existing) return existing;
    const parentPath = path.includes("/") ? path.slice(0, path.lastIndexOf("/")) : "";
    const parent = ensureDir(parentPath);
    const node = emptyNode(path.slice(path.lastIndexOf("/") + 1), path, true);
    parent.children.push(node);
    byPath.set(path, node);
    return node;
  };

  for (const entry of entries) {
    const parts = entry.path.split("/").filter(Boolean);
    if (parts.length === 0) continue;
    if (entry.isDir) {
      ensureDir(entry.path);
      continue;
    }
    const parentPath = parts.slice(0, -1).join("/");
    const parent = ensureDir(parentPath);
    const node = emptyNode(entry.name, entry.path, false);
    node.file = entry;
    parent.children.push(node);
    byPath.set(entry.path, node);
  }

  const sortNodes = (nodes: TreeNode[]) => {
    nodes.sort((left, right) => {
      if (left.isDir !== right.isDir) return left.isDir ? -1 : 1;
      return left.name.localeCompare(right.name);
    });
    for (const node of nodes) sortNodes(node.children);
  };
  sortNodes(root.children);
  return root.children;
}

/** Keep only branches containing a match; matching directories are expanded. */
export function filterTree(nodes: TreeNode[], query: string): TreeNode[] {
  const needle = query.trim().toLowerCase();
  if (!needle) return nodes;

  const filterNode = (node: TreeNode): TreeNode | null => {
    const matchesSelf = node.name.toLowerCase().includes(needle) || node.path.toLowerCase().includes(needle);
    const children = node.children
      .map(filterNode)
      .filter((child): child is TreeNode => child !== null);
    if (!matchesSelf && children.length === 0) return null;
    return { ...node, children };
  };

  return nodes.map(filterNode).filter((node): node is TreeNode => node !== null);
}

/** Flatten the tree into rows honoring the expanded set. */
export function flattenTree(
  nodes: TreeNode[],
  expanded: Set<string>,
  depth = 0,
): Array<{ node: TreeNode; depth: number }> {
  const rows: Array<{ node: TreeNode; depth: number }> = [];
  for (const node of nodes) {
    rows.push({ node, depth });
    if (node.isDir && expanded.has(node.path)) {
      rows.push(...flattenTree(node.children, expanded, depth + 1));
    }
  }
  return rows;
}

export function collectDirectoryPaths(nodes: TreeNode[]): string[] {
  const paths: string[] = [];
  const walk = (items: TreeNode[]) => {
    for (const item of items) {
      if (item.isDir) {
        paths.push(item.path);
        walk(item.children);
      }
    }
  };
  walk(nodes);
  return paths;
}

export function pythonFiles(nodes: TreeNode[]): string[] {
  const files: string[] = [];
  const walk = (items: TreeNode[]) => {
    for (const item of items) {
      if (item.isDir) walk(item.children);
      else if (item.file?.isPython) files.push(item.path);
    }
  };
  walk(nodes);
  return files;
}
