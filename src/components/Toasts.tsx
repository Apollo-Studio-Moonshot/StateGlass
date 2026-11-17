import { useStore, type Toast } from "../store";
import { AlertIcon, CheckIcon, CloseIcon } from "./Icons";
import { IconButton } from "./ui";

export function Toasts() {
  const toasts = useStore((state) => state.toasts);
  const dismiss = useStore((state) => state.dismissToast);

  if (toasts.length === 0) return null;

  return (
    <div className="toast-stack" role="status" aria-live="polite">
      {toasts.map((toast: Toast) => (
        <div key={toast.id} className={`toast toast-${toast.tone}`}>
          <span className="toast-icon">
            {toast.tone === "error" ? (
              <AlertIcon size={14} />
            ) : toast.tone === "success" ? (
              <CheckIcon size={14} />
            ) : (
              <span className="toast-dot" />
            )}
          </span>
          <span className="toast-message">{toast.message}</span>
          <IconButton title="Dismiss" onClick={() => dismiss(toast.id)}>
            <CloseIcon size={12} />
          </IconButton>
        </div>
      ))}
    </div>
  );
}
