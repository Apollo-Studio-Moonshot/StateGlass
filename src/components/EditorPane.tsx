import { useEffect, useMemo, useRef, useState } from "react";
import Editor, { type OnMount } from "@monaco-editor/react";
import type { editor as MonacoEditor } from "monaco-editor";
import { useStore } from "../store";
import { basename, dirname } from "../lib/format";
import { EmptyState, IconButton, Kbd } from "./ui";
import { CloseIcon, FileIcon, PythonIcon, SaveIcon } from "./Icons";

const TRACE_HIGHLIGHT_DECORATION = "trace-line-highlight";

export function EditorPane() {
  const openFiles = useStore((state) => state.openFiles);
  const activeFile = useStore((state) => state.activeFile);
  const setActiveFile = useStore((state) => state.setActiveFile);
  const closeFile = useStore((state) => state.closeFile);
  const updateFileContent = useStore((state) => state.updateFileContent);
  const saveFile = useStore((state) => state.saveFile);
  const reveal = useStore((state) => state.reveal);
  const workspace = useStore((state) => state.workspace);
  const files = useStore((state) => state.files);
  const openFile = useStore((state) => state.openFile);

  const editorRef = useRef<MonacoEditor.IStandaloneCodeEditor | null>(null);
  const decorationsRef = useRef<string[]>([]);
  const [cursor, setCursor] = useState({ line: 1, column: 1 });

  const current = openFiles.find((file) => file.path === activeFile) ?? null;
  const modelPath = current ? `${workspace?.root ?? "project"}/${current.path}` : undefined;
  const suggestions = useMemo(
    () => files.filter((file) => !file.isDir && file.isPython).slice(0, 7),
    [files],
  );

  const handleMount: OnMount = (editor) => {
    editorRef.current = editor;
    editor.onDidChangeCursorPosition((event) => {
      setCursor({ line: event.position.lineNumber, column: event.position.column });
    });
    editor.focus();
  };

  useEffect(() => {
    const editor = editorRef.current;
    if (!editor || !reveal || !current || reveal.file !== current.path) return;
    const model = editor.getModel();
    if (!model || model.getLineCount() < reveal.line) return;
    editor.revealLineInCenter(reveal.line, 0);
    editor.setPosition({ lineNumber: reveal.line, column: 1 });
    decorationsRef.current = editor.deltaDecorations(decorationsRef.current, [
      {
        range: { startLineNumber: reveal.line, startColumn: 1, endLineNumber: reveal.line, endColumn: 1 },
        options: {
          isWholeLine: true,
          className: TRACE_HIGHLIGHT_DECORATION,
          linesDecorationsClassName: "trace-line-gutter",
        },
      },
    ]);
  }, [reveal, current]);

  useEffect(() => {
    return () => {
      decorationsRef.current = [];
    };
  }, []);

  return (
    <div className="editor-pane">
      <div className="file-tabs" role="tablist">
        {openFiles.length === 0 && <span className="file-tabs-empty">No open files</span>}
        {openFiles.map((file) => {
          const dirty = file.content !== file.savedContent;
          return (
            <div
              key={file.path}
              role="tab"
              aria-selected={file.path === activeFile}
              className={`file-tab${file.path === activeFile ? " active" : ""}`}
              onClick={() => setActiveFile(file.path)}
              title={file.path}
            >
              <span className="file-tab-icon">
                {file.path.endsWith(".py") ? <PythonIcon size={13} /> : <FileIcon size={13} />}
              </span>
              <span className="file-tab-name">{basename(file.path)}</span>
              {dirty ? (
                <span className="dirty-dot" title="Unsaved changes" />
              ) : null}
              <button
                type="button"
                className="file-tab-close"
                aria-label={`Close ${basename(file.path)}`}
                title="Close"
                onClick={(event) => {
                  event.stopPropagation();
                  closeFile(file.path);
                }}
              >
                <CloseIcon size={11} />
              </button>
            </div>
          );
        })}
        <div className="file-tabs-spacer" />
        {current && (
          <div className="editor-actions">
            <span className={`save-state${current.content !== current.savedContent ? " dirty" : ""}`}>
              {current.content !== current.savedContent ? "Unsaved" : "Saved"}
            </span>
            <IconButton title="Save file (⌘S)" onClick={() => void saveFile(current.path)}>
              <SaveIcon size={14} />
            </IconButton>
          </div>
        )}
      </div>

      {current ? (
        <div className="editor-host">
          <Editor
            path={modelPath}
            language={current.language}
            value={current.content}
            theme="stateglass-dark"
            onChange={(value) => updateFileContent(current.path, value ?? "")}
            onMount={handleMount}
            options={{
              automaticLayout: true,
              fontFamily:
                '"SF Mono", "JetBrains Mono", "Fira Code", ui-monospace, Menlo, Consolas, monospace',
              fontSize: 13,
              lineHeight: 21,
              fontLigatures: true,
              minimap: { enabled: false },
              scrollBeyondLastLine: false,
              smoothScrolling: true,
              cursorBlinking: "smooth",
              cursorSmoothCaretAnimation: "on",
              renderLineHighlight: "all",
              padding: { top: 14, bottom: 14 },
              tabSize: 4,
              insertSpaces: true,
              glyphMargin: false,
              folding: true,
              lineNumbersMinChars: 4,
              overviewRulerLanes: 0,
              hideCursorInOverviewRuler: true,
              overviewRulerBorder: false,
              renderWhitespace: "selection",
              bracketPairColorization: { enabled: true },
              stickyScroll: { enabled: true },
              scrollbar: {
                verticalScrollbarSize: 10,
                horizontalScrollbarSize: 10,
                useShadows: false,
              },
              wordWrap: "off",
              contextmenu: true,
              quickSuggestions: { other: true, comments: false, strings: false },
              suggest: { showWords: true },
            }}
          />
          <div className="editor-status">
            <span className="editor-status-path" title={current.path}>
              {dirname(current.path) || "."}
            </span>
            <span className="editor-status-spacer" />
            <span>{current.language}</span>
            <span>
              Ln {cursor.line}, Col {cursor.column}
            </span>
            <span className="editor-status-save">
              <Kbd>⌘S</Kbd> save
            </span>
          </div>
        </div>
      ) : (
        <div className="editor-empty">
          <EmptyState
            icon={<FileIcon size={26} />}
            title="No file open"
            description={
              <>
                Choose a file in the explorer, or open one of the Python files below.
                <br />
                <span className="muted small">
                  <Kbd>⌘S</Kbd> save · <Kbd>⌘↵</Kbd> run · <Kbd>⌘O</Kbd> open project
                </span>
              </>
            }
            actions={
              suggestions.length > 0 ? (
                <div className="quick-open-list">
                  {suggestions.map((file) => (
                    <button
                      type="button"
                      key={file.path}
                      className="quick-open-item"
                      onClick={() => void openFile(file.path)}
                    >
                      <PythonIcon size={14} />
                      <span>{file.path}</span>
                    </button>
                  ))}
                </div>
              ) : undefined
            }
          />
        </div>
      )}
    </div>
  );
}
