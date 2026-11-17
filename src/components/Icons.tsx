import type { SVGProps } from "react";

type IconProps = SVGProps<SVGSVGElement> & { size?: number };

function Svg({ size = 16, children, ...rest }: IconProps) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.7}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      {...rest}
    >
      {children}
    </svg>
  );
}

export const PlayIcon = (props: IconProps) => (
  <Svg {...props}>
    <path d="M8 5.5v13l11-6.5L8 5.5Z" fill="currentColor" stroke="none" />
  </Svg>
);

export const StopIcon = (props: IconProps) => (
  <Svg {...props}>
    <rect x="7" y="7" width="10" height="10" rx="1.5" fill="currentColor" stroke="none" />
  </Svg>
);

export const FolderIcon = (props: IconProps) => (
  <Svg {...props}>
    <path d="M3.5 7.5A1.5 1.5 0 0 1 5 6h4l2 2h8a1.5 1.5 0 0 1 1.5 1.5v8A1.5 1.5 0 0 1 19 19H5a1.5 1.5 0 0 1-1.5-1.5v-10Z" />
  </Svg>
);

export const FileIcon = (props: IconProps) => (
  <Svg {...props}>
    <path d="M6.5 3.5h7l4 4v13h-11v-17Z" />
    <path d="M13.5 3.5v4h4" />
  </Svg>
);

export const ChevronRightIcon = (props: IconProps) => (
  <Svg {...props}>
    <path d="m9.5 6.5 5 5.5-5 5.5" />
  </Svg>
);

export const ChevronDownIcon = (props: IconProps) => (
  <Svg {...props}>
    <path d="m6.5 9.5 5.5 5 5.5-5" />
  </Svg>
);

export const SearchIcon = (props: IconProps) => (
  <Svg {...props}>
    <circle cx="10.5" cy="10.5" r="5.5" />
    <path d="m15 15 4.5 4.5" />
  </Svg>
);

export const SaveIcon = (props: IconProps) => (
  <Svg {...props}>
    <path d="M5 4.5h11l3 3v12H5v-15Z" />
    <path d="M8 4.5v5h7v-5M8 19.5v-6h8v6" />
  </Svg>
);

export const ExperimentIcon = (props: IconProps) => (
  <Svg {...props}>
    <path d="M9 3.5h6M10.5 3.5v6l-5 9.5a2 2 0 0 0 1.8 3h9.4a2 2 0 0 0 1.8-3l-5-9.5v-6" />
    <path d="M7.5 15.5h9" />
  </Svg>
);

export const FlowIcon = (props: IconProps) => (
  <Svg {...props}>
    <circle cx="5.5" cy="6" r="2" />
    <circle cx="18.5" cy="6" r="2" />
    <circle cx="12" cy="18" r="2" />
    <path d="M7.5 6h9M6.5 7.8l4.2 8.4M17.5 7.8l-4.2 8.4" />
  </Svg>
);

export const CompareIcon = (props: IconProps) => (
  <Svg {...props}>
    <path d="M8 4.5v15M16 4.5v15" />
    <path d="M4.5 8h5M14.5 16h5" />
  </Svg>
);

export const TerminalIcon = (props: IconProps) => (
  <Svg {...props}>
    <rect x="3" y="4.5" width="18" height="15" rx="2" />
    <path d="m7.5 9.5 3 2.5-3 2.5M12.5 15h4" />
  </Svg>
);

export const CloseIcon = (props: IconProps) => (
  <Svg {...props}>
    <path d="m6 6 12 12M18 6 6 18" />
  </Svg>
);

export const PanelLeftIcon = (props: IconProps) => (
  <Svg {...props}>
    <rect x="3" y="4.5" width="18" height="15" rx="2" />
    <path d="M9.5 4.5v15" />
  </Svg>
);

export const PanelRightIcon = (props: IconProps) => (
  <Svg {...props}>
    <rect x="3" y="4.5" width="18" height="15" rx="2" />
    <path d="M14.5 4.5v15" />
  </Svg>
);

export const SettingsIcon = (props: IconProps) => (
  <Svg {...props}>
    <circle cx="12" cy="12" r="3" />
    <path d="M19 12a7 7 0 0 0-.1-1.2l2-1.5-2-3.4-2.3 1a7 7 0 0 0-2-1.2L14.3 3h-4.6L9.4 5.7a7 7 0 0 0-2 1.2l-2.3-1-2 3.4 2 1.5A7 7 0 0 0 5 12c0 .4 0 .8.1 1.2l-2 1.5 2 3.4 2.3-1a7 7 0 0 0 2 1.2l.3 2.7h4.6l.3-2.7a7 7 0 0 0 2-1.2l2.3 1 2-3.4-2-1.5c.1-.4.1-.8.1-1.2Z" />
  </Svg>
);

export const RefreshIcon = (props: IconProps) => (
  <Svg {...props}>
    <path d="M20 11a8 8 0 1 0-2.3 6.3" />
    <path d="M20 5v6h-6" />
  </Svg>
);

export const CheckIcon = (props: IconProps) => (
  <Svg {...props}>
    <path d="m5 12.5 4.5 4.5L19 7" />
  </Svg>
);

export const AlertIcon = (props: IconProps) => (
  <Svg {...props}>
    <path d="M12 4 2.8 20h18.4L12 4Z" />
    <path d="M12 9.5v4.5M12 17.2v.3" />
  </Svg>
);

export const ClockIcon = (props: IconProps) => (
  <Svg {...props}>
    <circle cx="12" cy="12" r="8.5" />
    <path d="M12 7.5V12l3 2" />
  </Svg>
);

export const MemoryIcon = (props: IconProps) => (
  <Svg {...props}>
    <rect x="6" y="6" width="12" height="12" rx="2" />
    <path d="M9.5 3.5v2.5M14.5 3.5v2.5M9.5 18v2.5M14.5 18v2.5M3.5 9.5H6M3.5 14.5H6M18 9.5h2.5M18 14.5h2.5" />
  </Svg>
);

export const PlusIcon = (props: IconProps) => (
  <Svg {...props}>
    <path d="M12 5v14M5 12h14" />
  </Svg>
);

export const ArrowRightIcon = (props: IconProps) => (
  <Svg {...props}>
    <path d="M4.5 12h15M13.5 6l6 6-6 6" />
  </Svg>
);

export const LayersIcon = (props: IconProps) => (
  <Svg {...props}>
    <path d="m12 3.5 9 5-9 5-9-5 9-5Z" />
    <path d="m3.5 12.5 8.5 4.7 8.5-4.7M3.5 16.8l8.5 4.7 8.5-4.7" />
  </Svg>
);

export const PythonIcon = (props: IconProps) => (
  <Svg {...props}>
    <path d="M12 3.5c-3.2 0-4.8 1-4.8 3.2v2.4h5v1.1H6.4c-2.2 0-3.4 1.7-3.4 4.8s1.2 4.8 3.4 4.8h1.9v-2.7c0-2 1.6-3.5 3.6-3.5h4.4c1.9 0 3.1-1.4 3.1-3.2V6.7c0-2.1-1.9-3.2-4.5-3.2H12Z" />
    <path d="M12 20.5c3.2 0 4.8-1 4.8-3.2v-2.4h-5v-1.1h5.8c2.2 0 3.4-1.7 3.4-4.8s-1.2-4.8-3.4-4.8h-1.9v2.7c0 2-1.6 3.5-3.6 3.5H8.7c-1.9 0-3.1 1.4-3.1 3.2v2.7c0 2.1 1.9 3.2 4.5 3.2H12Z" opacity=".55" />
  </Svg>
);

export const VariableIcon = (props: IconProps) => (
  <Svg {...props}>
    <path d="M8.5 4.5c-2 0-2.5 1-2.5 3v2c0 1.2-.7 2-2 2.5 1.3.5 2 1.3 2 2.5v2c0 2 .5 3 2.5 3" />
    <path d="M15.5 4.5c2 0 2.5 1 2.5 3v2c0 1.2.7 2 2 2.5-1.3.5-2 1.3-2 2.5v2c0 2-.5 3-2.5 3" />
  </Svg>
);

export const KeyboardIcon = (props: IconProps) => (
  <Svg {...props}>
    <rect x="2.5" y="6.5" width="19" height="11" rx="2" />
    <path d="M6 10h.01M9.5 10h.01M13 10h.01M16.5 10h.01M6 13.5h.01M9.5 13.5h.01M13 13.5h.01M16.5 13.5h.01M8 16.5h8" />
  </Svg>
);

export const ChevronUpDownIcon = (props: IconProps) => (
  <Svg {...props}>
    <path d="m8 9.5 4-4 4 4M8 14.5l4 4 4-4" />
  </Svg>
);

export const PinIcon = (props: IconProps) => (
  <Svg {...props}>
    <path d="M12 17v5" />
    <path d="M9 10.8a2 2 0 0 1-1.1 1.8l-1.8.9A2 2 0 0 0 5 15.2V16a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-.8a2 2 0 0 0-1.1-1.8l-1.8-.9A2 2 0 0 1 15 10.8V7a1 1 0 0 1 1-1 2 2 0 0 0 0-4H8a2 2 0 0 0 0 4 1 1 0 0 1 1 1v3.8Z" />
  </Svg>
);

export const Logo = ({ size = 20 }: { size?: number }) => (
  <svg width={size} height={size} viewBox="0 0 24 24" fill="none" aria-hidden="true">
    <rect x="2.5" y="2.5" width="19" height="19" rx="5" fill="var(--logo-bg, #10151c)" />
    <rect x="2.5" y="2.5" width="19" height="19" rx="5" stroke="var(--logo-border, #263140)" />
    <path
      d="M6.5 16 9.7 11.8l3 2.2 2.6-4.4 2.6 1.6"
      stroke="var(--accent)"
      strokeWidth="1.8"
      strokeLinecap="round"
      strokeLinejoin="round"
    />
    <circle cx="6.5" cy="16" r="1.5" fill="var(--text)" />
    <circle cx="9.7" cy="11.8" r="1.5" fill="var(--text)" />
    <circle cx="12.7" cy="14" r="1.5" fill="var(--text)" />
    <circle cx="15.3" cy="9.6" r="1.5" fill="var(--text)" />
    <circle cx="17.9" cy="11.2" r="1.5" fill="var(--text)" />
  </svg>
);
