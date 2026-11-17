/** Monaco editor bootstrap: local workers, dark theme tuned for Stateglass. */

import * as monaco from "monaco-editor";
import { loader } from "@monaco-editor/react";
import EditorWorker from "monaco-editor/esm/vs/editor/editor.worker?worker";

declare global {
  interface Window {
    MonacoEnvironment?: monaco.Environment;
  }
}

window.MonacoEnvironment = {
  getWorker() {
    return new EditorWorker();
  },
};

monaco.editor.defineTheme("stateglass-dark", {
  base: "vs-dark",
  inherit: true,
  rules: [
    { token: "", foreground: "d7dee9", background: "0d1015" },
    { token: "comment", foreground: "5f6b7c", fontStyle: "italic" },
    { token: "keyword", foreground: "8cabff" },
    { token: "keyword.control", foreground: "8cabff" },
    { token: "string", foreground: "9bd6b2" },
    { token: "number", foreground: "e0b382" },
    { token: "type", foreground: "6fd1d4" },
    { token: "type.identifier", foreground: "6fd1d4" },
    { token: "identifier", foreground: "d7dee9" },
    { token: "delimiter", foreground: "7b869a" },
    { token: "operators", foreground: "a9b5c7" },
    { token: "function", foreground: "b8c7ff" },
    { token: "variable", foreground: "d7dee9" },
    { token: "constant", foreground: "e0b382" },
    { token: "tag", foreground: "8cabff" },
    { token: "attribute.name", foreground: "9bd6b2" },
  ],
  colors: {
    "editor.background": "#0d1015",
    "editor.foreground": "#d7dee9",
    "editorLineNumber.foreground": "#3f4857",
    "editorLineNumber.activeForeground": "#8b95a7",
    "editor.lineHighlightBackground": "#12161d",
    "editor.selectionBackground": "#24344d",
    "editor.inactiveSelectionBackground": "#1a2536",
    "editorCursor.foreground": "#7ea6ff",
    "editorIndentGuide.background1": "#171d26",
    "editorIndentGuide.activeBackground1": "#2b3442",
    "editorWidget.background": "#11151b",
    "editorWidget.border": "#232b36",
    "editorSuggestWidget.background": "#11151b",
    "editorSuggestWidget.selectedBackground": "#1d2634",
    "editorHoverWidget.background": "#11151b",
    "editorBracketMatch.background": "#1c2a3d",
    "editorBracketMatch.border": "#37506e",
    "scrollbarSlider.background": "#2b3442aa",
    "scrollbarSlider.hoverBackground": "#3a4557",
    "scrollbarSlider.activeBackground": "#4a566a",
    "minimap.background": "#0b0e13",
  },
});

loader.config({ monaco });

export { monaco };
