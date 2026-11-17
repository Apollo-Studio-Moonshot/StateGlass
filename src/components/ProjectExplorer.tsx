import { useEffect, useMemo, useState } from "react";
import { useStore } from "../store";
import { buildFileTree, flattenTree, collectDirectoryPaths, filterTree } from "../lib/tree";
import { formatBytes } from "../lib/format";
import { IconButton, PanelHeader, Spinner, EmptyState } from "./ui";
import {
  ChevronDownIcon,
  ChevronRightIcon,
  ChevronUpDownIcon,
  ExperimentIcon,
  FileIcon,
  FolderIcon,
  PlayIcon,
  PythonIcon,
  RefreshIcon,
  SearchIcon,
} from "./Icons";

export function ProjectExplorer() {
  const files = useStore((state) => state.files);
  const filesLoading = useStore((state) => state.filesLoading);
  const activeFile = useStore((state) => state.activeFile);
  const openFiles = useStore((state) => state.openFiles);
  const openFile = useStore((state) => state.openFile);
  const refreshFiles = useStore((state) => state.refreshFiles);
  const workspace = useStore((state) => state.workspace);
  const project = useStore((state) => state.project);
  const updateConfig = useStore((state) => state.updateConfig);

  const [query, setQuery] = useState("");
  const [collapsed, setCollapsed] = useState<Set<string>>(new Set());

  useEffect(() => {
    setCollapsed(new Set());
    setQuery("");
  }, [workspace?.root]);

  const tree = useMemo(() => buildFileTree(files), [files]);
  const filtered = useMemo(() => filterTree(tree, query), [tree, query]);
  const expanded = useMemo(() => {
    const all = new Set(collectDirectoryPaths(tree));
    for (const path of collapsed) all.delete(path);
    return all;
  }, [tree, collapsed]);
  const rows = useMemo(
    () =>
      flattenTree(
        filtered,
        query.trim() ? new Set(collectDirectoryPaths(filtered)) : expanded,
      ),
    [filtered, expanded, query],
  );

  const dirtyPaths = useMemo(
    () => new Set(openFiles.filter((file) => file.content !== file.savedContent).map((file) => file.path)),
    [openFiles],
  );

  const toggleDirectory = (path: string) => {
    setCollapsed((current) => {
      const next = new Set(current);
      if (next.has(path)) next.delete(path);
      else next.add(path);
      return next;
    });
  };

  const toggleAll = () => {
    if (collapsed.size > 0) setCollapsed(new Set());
    else setCollapsed(new Set(collectDirectoryPaths(tree)));
  };

  const markEntry = async (path: string) => {
    if (!project || workspace?.kind === "experiment") return;
    await updateConfig({
      entryPoint: path,
      runArgs: project.runArgs,
      timeoutMs: project.timeoutMs,
      tracing: project.tracing,
      pythonPath: project.pythonPath,
    });
  };

  return (
    <div className="explorer">
      <PanelHeader
        title="Explorer"
        count={files.length}
        actions={
          <>
            {filesLoading && <Spinner size={12} />}
            <IconButton title="Collapse or expand all folders" onClick={toggleAll}>
              <ChevronUpDownIcon size={14} />
            </IconButton>
            <IconButton title="Refresh file list" onClick={() => void refreshFiles()}>
              <RefreshIcon size={14} />
            </IconButton>
          </>
        }
      />

      <div className="explorer-search">
        <SearchIcon size={13} />
        <input
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          placeholder="Filter files…"
          spellCheck={false}
          aria-label="Filter files"
        />
      </div>

      <div className="explorer-tree" role="tree">
        {rows.length === 0 && !filesLoading && (
          <EmptyState
            compact
            icon={<FolderIcon size={22} />}
            title={query ? "No matching files" : "No files to show"}
            description={query ? "Try a different filter." : "Ignored folders such as .git and venv are hidden."}
          />
        )}
        {rows.map(({ node, depth }) => {
          const isEntry = !node.isDir && node.path === project?.entryPoint;
          const isActive = !node.isDir && node.path === activeFile;
          const isDirty = dirtyPaths.has(node.path);
          return (
            <div
              key={node.path}
              role="treeitem"
              aria-level={depth + 1}
              aria-expanded={node.isDir ? !collapsed.has(node.path) : undefined}
              className={`tree-row${isActive ? " active" : ""}${node.isDir ? " dir" : ""}`}
              style={{ paddingLeft: 8 + depth * 14 }}
              onClick={() => {
                if (node.isDir) toggleDirectory(node.path);
                else void openFile(node.path);
              }}
              title={node.path}
            >
              <span className="tree-chevron">
                {node.isDir &&
                  (collapsed.has(node.path) && !query.trim() ? (
                    <ChevronRightIcon size={12} />
                  ) : (
                    <ChevronDownIcon size={12} />
                  ))}
              </span>
              <span className={`tree-icon ${node.isDir ? "folder" : node.file?.isPython ? "python" : ""}`}>
                {node.isDir ? <FolderIcon size={14} /> : node.file?.isPython ? <PythonIcon size={14} /> : <FileIcon size={14} />}
              </span>
              <span className="tree-name">{node.name}</span>
              {isDirty && <span className="dirty-dot" title="Unsaved changes" />}
              {isEntry && (
                <span className="entry-badge" title="Entry point">
                  <PlayIcon size={9} />
                </span>
              )}
              {!node.isDir && (
                <span className="tree-actions">
                  {!isEntry && node.file?.isPython && workspace?.kind !== "experiment" && (
                    <button
                      type="button"
                      className="tree-action"
                      title="Set as entry point"
                      onClick={(event) => {
                        event.stopPropagation();
                        void markEntry(node.path);
                      }}
                    >
                      <PlayIcon size={11} />
                    </button>
                  )}
                  <span className="tree-size">{formatBytes(node.file?.size ?? 0)}</span>
                </span>
              )}
            </div>
          );
        })}
      </div>

      <div className={`explorer-footer${workspace?.kind === "experiment" ? " experiment" : ""}`}>
        {workspace?.kind === "experiment" ? (
          <>
            <ExperimentIcon size={13} />
            <div>
              <strong>Editing an experiment copy</strong>
              <span title={workspace.root}>{workspace.label}</span>
            </div>
          </>
        ) : (
          <>
            <FolderIcon size={13} />
            <span title={project?.rootPath ?? ""}>Source folder · read/write</span>
          </>
        )}
      </div>
    </div>
  );
}
