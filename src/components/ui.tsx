import {
  useEffect,
  useRef,
  useState,
  type ReactNode,
} from "react";
import { CloseIcon, ChevronRightIcon } from "./Icons";

/* -------------------------------------------------------------------------- */
/* Panel header                                                               */
/* -------------------------------------------------------------------------- */

export function PanelHeader({
  title,
  count,
  subtitle,
  icon,
  actions,
}: {
  title: string;
  count?: number | string;
  subtitle?: string;
  icon?: ReactNode;
  actions?: ReactNode;
}) {
  return (
    <div className="panel-header">
      <div className="panel-header-title">
        {icon && <span className="panel-header-icon">{icon}</span>}
        <span>{title}</span>
        {count !== undefined && <span className="panel-count">{count}</span>}
        {subtitle && <span className="panel-subtitle">{subtitle}</span>}
      </div>
      {actions && <div className="panel-header-actions">{actions}</div>}
    </div>
  );
}

/* -------------------------------------------------------------------------- */
/* Empty state                                                                */
/* -------------------------------------------------------------------------- */

export function EmptyState({
  icon,
  title,
  description,
  actions,
  compact,
}: {
  icon?: ReactNode;
  title: string;
  description?: ReactNode;
  actions?: ReactNode;
  compact?: boolean;
}) {
  return (
    <div className={`empty-state${compact ? " compact" : ""}`}>
      {icon && <div className="empty-icon">{icon}</div>}
      <div className="empty-title">{title}</div>
      {description && <div className="empty-description">{description}</div>}
      {actions && <div className="empty-actions">{actions}</div>}
    </div>
  );
}

/* -------------------------------------------------------------------------- */
/* Badges & status                                                            */
/* -------------------------------------------------------------------------- */

export type Tone = "neutral" | "accent" | "success" | "danger" | "warning" | "violet";

export function Badge({
  tone = "neutral",
  children,
  title,
}: {
  tone?: Tone;
  children: ReactNode;
  title?: string;
}) {
  return (
    <span className={`badge badge-${tone}`} title={title}>
      {children}
    </span>
  );
}

export function StatusDot({ status }: { status: string }) {
  const tone =
    status === "ok"
      ? "success"
      : status === "running"
        ? "accent"
        : status === "timeout"
          ? "warning"
          : status === "cancelled"
            ? "neutral"
            : "danger";
  return <span className={`status-dot status-${tone}${status === "running" ? " pulsing" : ""}`} />;
}

export function Spinner({ size = 14 }: { size?: number }) {
  return <span className="spinner" style={{ width: size, height: size }} aria-label="Loading" />;
}

/* -------------------------------------------------------------------------- */
/* Buttons & inputs                                                           */
/* -------------------------------------------------------------------------- */

export function IconButton({
  title,
  onClick,
  children,
  active,
  disabled,
  className = "",
}: {
  title: string;
  onClick?: () => void;
  children: ReactNode;
  active?: boolean;
  disabled?: boolean;
  className?: string;
}) {
  return (
    <button
      type="button"
      className={`icon-button${active ? " active" : ""} ${className}`}
      title={title}
      aria-label={title}
      onClick={onClick}
      disabled={disabled}
    >
      {children}
    </button>
  );
}

export function Kbd({ children }: { children: ReactNode }) {
  return <kbd className="kbd">{children}</kbd>;
}

export function Field({
  label,
  hint,
  children,
  error,
}: {
  label: string;
  hint?: string;
  children: ReactNode;
  error?: string | null;
}) {
  return (
    <label className="field">
      <span className="field-label">{label}</span>
      {children}
      {error ? <span className="field-error">{error}</span> : hint ? <span className="field-hint">{hint}</span> : null}
    </label>
  );
}

export function Toggle({
  checked,
  onChange,
  label,
  description,
}: {
  checked: boolean;
  onChange: (value: boolean) => void;
  label: string;
  description?: string;
}) {
  return (
    <button
      type="button"
      className={`toggle-row${checked ? " on" : ""}`}
      onClick={() => onChange(!checked)}
      role="switch"
      aria-checked={checked}
    >
      <span className={`toggle-track`}>
        <span className="toggle-thumb" />
      </span>
      <span className="toggle-text">
        <span className="toggle-label">{label}</span>
        {description && <span className="toggle-description">{description}</span>}
      </span>
    </button>
  );
}

/* -------------------------------------------------------------------------- */
/* Modal                                                                      */
/* -------------------------------------------------------------------------- */

export function Modal({
  title,
  subtitle,
  children,
  footer,
  onClose,
  width = 560,
  tone = "neutral",
}: {
  title: string;
  subtitle?: ReactNode;
  children: ReactNode;
  footer?: ReactNode;
  onClose: () => void;
  width?: number;
  tone?: "neutral" | "warning";
}) {
  useEffect(() => {
    const handler = (event: KeyboardEvent) => {
      if (event.key === "Escape") onClose();
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, [onClose]);

  return (
    <div className="modal-backdrop" onMouseDown={onClose}>
      <div
        className={`modal tone-${tone}`}
        style={{ width }}
        role="dialog"
        aria-modal="true"
        aria-label={title}
        onMouseDown={(event) => event.stopPropagation()}
      >
        <div className="modal-header">
          <div>
            <h2>{title}</h2>
            {subtitle && <p className="modal-subtitle">{subtitle}</p>}
          </div>
          <IconButton title="Close" onClick={onClose}>
            <CloseIcon size={15} />
          </IconButton>
        </div>
        <div className="modal-body">{children}</div>
        {footer && <div className="modal-footer">{footer}</div>}
      </div>
    </div>
  );
}

/* -------------------------------------------------------------------------- */
/* Popover                                                                    */
/* -------------------------------------------------------------------------- */

export function Popover({
  trigger,
  children,
  align = "right",
  width,
  className = "",
}: {
  trigger: (open: boolean) => ReactNode;
  children: ReactNode | ((close: () => void) => ReactNode);
  align?: "left" | "right";
  width?: number;
  className?: string;
}) {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) return;
    const onPointerDown = (event: MouseEvent) => {
      if (ref.current && !ref.current.contains(event.target as Node)) setOpen(false);
    };
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") setOpen(false);
    };
    window.addEventListener("mousedown", onPointerDown);
    window.addEventListener("keydown", onKey);
    return () => {
      window.removeEventListener("mousedown", onPointerDown);
      window.removeEventListener("keydown", onKey);
    };
  }, [open]);

  return (
    <div className="popover-root" ref={ref}>
      <div className={`popover-trigger${open ? " open" : ""}`} onClick={() => setOpen((value) => !value)}>
        {trigger(open)}
      </div>
      {open && (
        <div
          className={`popover-panel align-${align} ${className}`}
          style={width ? { width } : undefined}
          onMouseDown={(event) => event.stopPropagation()}
        >
          {typeof children === "function" ? children(() => setOpen(false)) : children}
        </div>
      )}
    </div>
  );
}

/* -------------------------------------------------------------------------- */
/* Dropdown select                                                            */
/* -------------------------------------------------------------------------- */

export interface DropdownOption {
  value: string;
  label: string;
  description?: string;
  meta?: ReactNode;
  disabled?: boolean;
}

export function DropdownSelect({
  value,
  options,
  onChange,
  placeholder = "Select…",
  renderValue,
  width = 280,
  align = "left",
  className = "",
  disabled,
}: {
  value: string | null;
  options: DropdownOption[];
  onChange: (value: string) => void;
  placeholder?: string;
  renderValue?: (option: DropdownOption | null) => ReactNode;
  width?: number;
  align?: "left" | "right";
  className?: string;
  disabled?: boolean;
}) {
  const selected = options.find((option) => option.value === value) ?? null;
  return (
    <Popover
      align={align}
      width={width}
      className="dropdown-panel"
      trigger={(open) => (
        <button
          type="button"
          className={`dropdown-trigger ${open ? " open" : ""} ${className}`}
          disabled={disabled}
        >
          <span className="dropdown-value">
            {renderValue
              ? renderValue(selected)
              : (selected?.label ?? <span className="muted">{placeholder}</span>)}
          </span>
          <ChevronRightIcon size={13} className="dropdown-chevron" />
        </button>
      )}
    >
      {(close) => (
        <div className="dropdown-list">
          {options.length === 0 && <div className="dropdown-empty">No options available</div>}
          {options.map((option) => (
            <button
              type="button"
              key={option.value}
              className={`dropdown-option${option.value === value ? " selected" : ""}`}
              onClick={() => {
                if (option.disabled) return;
                onChange(option.value);
                close();
              }}
              disabled={option.disabled}
            >
              <span className="dropdown-option-body">
                <span className="dropdown-option-label">{option.label}</span>
                {option.description && (
                  <span className="dropdown-option-description">{option.description}</span>
                )}
              </span>
              {option.meta}
            </button>
          ))}
        </div>
      )}
    </Popover>
  );
}
