import type { FileEntry } from "../types";

export function rankQuickOpenFiles(
  files: FileEntry[],
  query: string,
  openPaths: string[],
  activePath: string | null,
): FileEntry[] {
  const terms = query.trim().toLowerCase().split(/\s+/).filter(Boolean);
  const openOrder = new Map(openPaths.map((path, index) => [path, index]));

  return files
    .map((file, index) => {
      if (file.isDir) return null;
      const path = file.path.toLowerCase();
      const name = file.name.toLowerCase();
      let score = 0;
      for (const term of terms) {
        const position = path.indexOf(term);
        if (position === -1) return null;
        score += position - (name.startsWith(term) ? 3 : 0);
      }
      return { file, index, score };
    })
    .filter((item): item is { file: FileEntry; index: number; score: number } => item !== null)
    .sort((left, right) => {
      if (terms.length > 0 && left.score !== right.score) return left.score - right.score;
      const leftActive = left.file.path === activePath;
      const rightActive = right.file.path === activePath;
      if (leftActive !== rightActive) return leftActive ? -1 : 1;
      const leftOpen = openOrder.get(left.file.path);
      const rightOpen = openOrder.get(right.file.path);
      if (leftOpen !== rightOpen) {
        if (leftOpen === undefined) return 1;
        if (rightOpen === undefined) return -1;
        return rightOpen - leftOpen;
      }
      return left.index - right.index;
    })
    .map((item) => item.file);
}
