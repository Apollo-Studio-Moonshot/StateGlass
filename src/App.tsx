import {
  Group as PanelGroup,
  Panel,
  Separator as PanelResizeHandle,
  type Layout,
} from "react-resizable-panels";
import { useEffect, useMemo } from "react";
import { useStore } from "./store";
import { pickProjectFolder } from "./lib/picker";
import { Header } from "./components/Header";
import { Welcome } from "./components/Welcome";
import { ProjectExplorer } from "./components/ProjectExplorer";
import { EditorPane } from "./components/EditorPane";
import { Timeline } from "./components/Timeline";
import { VariableInspector } from "./components/VariableInspector";
import { DataFlowPanel } from "./components/DataFlowPanel";
import { ComparePanel } from "./components/ComparePanel";
import { ExperimentsPanel } from "./components/ExperimentsPanel";
import { ConsolePanel } from "./components/ConsolePanel";
import { StatusBar } from "./components/StatusBar";
import { Dialogs } from "./components/Dialogs";
import { Toasts } from "./components/Toasts";
import { Spinner } from "./components/ui";
import {
  CompareIcon,
  ExperimentIcon,
  FileIcon,
  FlowIcon,
  Logo,
} from "./components/Icons";
import type { CenterTab } from "./types";

const CENTER_TABS: Array<{ id: CenterTab; label: string; icon: React.ReactNode }> = [
  { id: "editor", label: "Editor", icon: <FileIcon size={13} /> },
  { id: "flow", label: "Data Flow", icon: <FlowIcon size={13} /> },
  { id: "compare", label: "Compare", icon: <CompareIcon size={13} /> },
  { id: "experiments", label: "Experiments", icon: <ExperimentIcon size={13} /> },
];

export default function App() {
  const booting = useStore((state) => state.booting);
  const boot = useStore((state) => state.boot);
  const project = useStore((state) => state.project);
  const init = useStore((state) => state.init);
  const subscribeToEvents = useStore((state) => state.subscribeToEvents);
  const busy = useStore((state) => state.busy);

  useEffect(() => {
    void init();
  }, [init]);

  useEffect(() => {
    let stop: (() => void) | undefined;
    let disposed = false;
    void subscribeToEvents().then((unsubscribe) => {
      if (disposed) {
        unsubscribe();
        return;
      }
      stop = unsubscribe;
    });
    return () => {
      disposed = true;
      stop?.();
    };
  }, [subscribeToEvents]);

  useEffect(() => {
    document.title = project ? `${project.name} — Stateglass` : "Stateglass";
  }, [project]);

  useHotkeys();

  return (
    <>
      {booting && !boot ? (
        <BootScreen />
      ) : !project ? (
        <Welcome />
      ) : (
        <Shell />
      )}
      {busy && (
        <div className="busy-indicator">
          <Spinner size={13} />
          <span>{busy}</span>
        </div>
      )}
      <Toasts />
      <Dialogs />
    </>
  );
}

function BootScreen() {
  return (
    <div className="boot-screen">
      <Logo size={44} />
      <h1>Stateglass</h1>
      <div className="boot-loading">
        <Spinner size={14} />
        <span>Preparing workspace…</span>
      </div>
    </div>
  );
}

function Shell() {
  const explorerOpen = useStore((state) => state.explorerOpen);
  const inspectorOpen = useStore((state) => state.inspectorOpen);
  const consoleOpen = useStore((state) => state.consoleOpen);
  const mainLayout = usePersistedLayout("stateglass-main");
  const centerLayout = usePersistedLayout("stateglass-center");
  const inspectorLayout = usePersistedLayout("stateglass-inspector");

  return (
    <div className="app">
      <Header />
      <main className="workspace-area">
        <PanelGroup
          orientation="horizontal"
          className="panel-group"
          defaultLayout={mainLayout.defaultLayout}
          onLayoutChanged={mainLayout.onLayoutChanged}
        >
          {explorerOpen && (
            <>
              <Panel id="sg-explorer" defaultSize="18%" minSize="12%" maxSize="34%" className="panel">
                <ProjectExplorer />
              </Panel>
              <PanelResizeHandle className="resize-handle vertical" />
            </>
          )}
          <Panel id="sg-center" minSize="28%" className="panel">
            <PanelGroup
              orientation="vertical"
              className="panel-group"
              defaultLayout={centerLayout.defaultLayout}
              onLayoutChanged={centerLayout.onLayoutChanged}
            >
              <Panel id="sg-editor" minSize="20%" className="panel">
                <CenterArea />
              </Panel>
              {consoleOpen && (
                <>
                  <PanelResizeHandle className="resize-handle horizontal" />
                  <Panel
                    id="sg-console"
                    defaultSize="24%"
                    minSize="8%"
                    maxSize="60%"
                    className="panel"
                  >
                    <ConsolePanel />
                  </Panel>
                </>
              )}
            </PanelGroup>
          </Panel>
          {inspectorOpen && (
            <>
              <PanelResizeHandle className="resize-handle vertical" />
              <Panel id="sg-inspector" defaultSize="28%" minSize="18%" maxSize="46%" className="panel">
                <PanelGroup
                  orientation="vertical"
                  className="panel-group"
                  defaultLayout={inspectorLayout.defaultLayout}
                  onLayoutChanged={inspectorLayout.onLayoutChanged}
                >
                  <Panel id="sg-vars" defaultSize="48%" minSize="18%" className="panel">
                    <VariableInspector />
                  </Panel>
                  <PanelResizeHandle className="resize-handle horizontal" />
                  <Panel id="sg-timeline" defaultSize="52%" minSize="18%" className="panel">
                    <Timeline />
                  </Panel>
                </PanelGroup>
              </Panel>
            </>
          )}
        </PanelGroup>
      </main>
      <StatusBar />
    </div>
  );
}

function CenterArea() {
  const centerTab = useStore((state) => state.centerTab);
  const setCenterTab = useStore((state) => state.setCenterTab);
  const selectedVariable = useStore((state) => state.selectedVariable);
  const experiments = useStore((state) => state.experiments);
  const comparison = useStore((state) => state.comparison);
  const session = useStore((state) => state.activeSession);

  const changedVariables =
    comparison?.variables.filter((variable) => variable.status !== "same").length ?? 0;

  return (
    <section className="center">
      <div className="center-tabs" role="tablist">
        {CENTER_TABS.map((tab) => (
          <button
            type="button"
            key={tab.id}
            role="tab"
            aria-selected={centerTab === tab.id}
            className={`center-tab${centerTab === tab.id ? " active" : ""}`}
            onClick={() => setCenterTab(tab.id)}
            title={`${tab.label} (⌘${CENTER_TABS.indexOf(tab) + 1})`}
          >
            {tab.icon}
            <span>{tab.label}</span>
            {tab.id === "flow" && selectedVariable && <span className="tab-dot accent" />}
            {tab.id === "compare" && changedVariables > 0 && (
              <span className="tab-count">{changedVariables}</span>
            )}
            {tab.id === "experiments" && experiments.length > 0 && (
              <span className="tab-count">{experiments.length}</span>
            )}
            {tab.id === "editor" && session?.status === "running" && (
              <span className="tab-dot accent pulsing" />
            )}
          </button>
        ))}
      </div>
      <div className="center-body">
        {centerTab === "editor" && <EditorPane />}
        {centerTab === "flow" && <DataFlowPanel />}
        {centerTab === "compare" && <ComparePanel />}
        {centerTab === "experiments" && <ExperimentsPanel />}
      </div>
    </section>
  );
}

function usePersistedLayout(key: string) {
  const defaultLayout = useMemo<Layout | undefined>(() => {
    try {
      const raw = window.localStorage.getItem(key);
      if (!raw) return undefined;
      const parsed = JSON.parse(raw) as Record<string, number>;
      return Object.keys(parsed).length > 0 ? parsed : undefined;
    } catch {
      return undefined;
    }
  }, [key]);
  return {
    defaultLayout,
    onLayoutChanged: (layout: Layout) => {
      try {
        window.localStorage.setItem(key, JSON.stringify(layout));
      } catch {
        /* layout persistence is best-effort */
      }
    },
  };
}

function useHotkeys() {
  useEffect(() => {
    const handler = (event: KeyboardEvent) => {
      const state = useStore.getState();
      const mod = event.metaKey || event.ctrlKey;
      const key = event.key.toLowerCase();
      const target = event.target as HTMLElement | null;
      const typing =
        !!target &&
        (target.tagName === "INPUT" ||
          target.tagName === "TEXTAREA" ||
          target.isContentEditable ||
          target.getAttribute("role") === "textbox");

      if (mod && key === "o") {
        event.preventDefault();
        void pickProjectFolder().then((path) => {
          if (path) void state.openProjectPath(path);
        });
        return;
      }
      if (mod && key === "s") {
        event.preventDefault();
        void state.saveFile();
        return;
      }
      if (mod && key === "p" && state.project) {
        event.preventDefault();
        state.setQuickOpenOpen(true);
        return;
      }
      if (mod && key === "w" && state.activeFile) {
        event.preventDefault();
        state.closeFile(state.activeFile);
        return;
      }
      if (mod && event.key === "Enter") {
        event.preventDefault();
        void state.run();
        return;
      }
      if (mod && event.key === ".") {
        event.preventDefault();
        void state.cancelRun();
        return;
      }
      if (mod && event.shiftKey && key === "e") {
        event.preventDefault();
        if (state.project) state.setNewExperimentOpen(true);
        return;
      }
      if (mod && event.shiftKey && key === "b") {
        event.preventDefault();
        state.toggleInspector();
        return;
      }
      if (mod && key === "b") {
        event.preventDefault();
        state.toggleExplorer();
        return;
      }
      if (mod && key === "j") {
        event.preventDefault();
        state.toggleConsole();
        return;
      }
      if (mod && ["1", "2", "3", "4"].includes(event.key)) {
        event.preventDefault();
        const tabs: CenterTab[] = ["editor", "flow", "compare", "experiments"];
        const index = Number(event.key) - 1;
        state.setCenterTab(tabs[index] ?? "editor");
        return;
      }
      if (!typing && event.key === "?") {
        event.preventDefault();
        state.setShortcutsOpen(true);
        return;
      }
      if (event.key === "Escape") {
        if (state.consentOpen) state.closeConsent();
        if (state.newExperimentOpen) state.setNewExperimentOpen(false);
        if (state.shortcutsOpen) state.setShortcutsOpen(false);
      }
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, []);
}
