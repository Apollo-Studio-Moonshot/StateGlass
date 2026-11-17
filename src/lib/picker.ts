import { open } from "@tauri-apps/plugin-dialog";

/** Ask the OS for a project directory. Returns null when the user cancels. */
export async function pickProjectFolder(): Promise<string | null> {
  try {
    const selected = await open({
      directory: true,
      multiple: false,
      title: "Open a local project",
    });
    return typeof selected === "string" ? selected : null;
  } catch {
    return null;
  }
}
