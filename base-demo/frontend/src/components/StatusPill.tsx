// StatusPill — single source of truth for payment-status colouring.
//
// The api-gateway returns a free-form `status` string from /process and
// /status/<id> ("accepted", "throttled", "declined", "not_found", and so
// on). Mapping each of those into a small allow-list of visual buckets
// here means a new status from the back-end will fall back to "neutral"
// rather than break the layout, and lets the Recent Payments table and
// the Status page share the exact same colour rules.

import { ReactNode } from "react";

export type StatusKind = "ok" | "warn" | "error" | "pending" | "neutral";

const KIND_LABEL: Record<StatusKind, string> = {
  ok: "Accepted",
  warn: "Throttled",
  error: "Declined",
  pending: "Pending",
  neutral: "Unknown",
};

// Server status string -> visual kind. The match is case-insensitive and
// substring-tolerant so "throttled_bronze" still reads as warn.
export function statusKindFor(serverStatus: string | null | undefined): StatusKind {
  if (!serverStatus) return "neutral";
  const s = String(serverStatus).toLowerCase();
  if (s.includes("accept") || s === "ok" || s === "completed" || s === "success") return "ok";
  if (s.includes("throttle") || s.includes("partial") || s.includes("retry")) return "warn";
  if (
    s.includes("decline")
    || s.includes("fail")
    || s.includes("error")
    || s.includes("reject")
  ) return "error";
  if (s.includes("pending") || s.includes("queued") || s.includes("processing")) return "pending";
  if (s.includes("not_found") || s.includes("missing")) return "neutral";
  return "neutral";
}

interface Props {
  // Either the raw server status string, or a pre-computed visual kind.
  // Passing the server string is the common case; the kind override is
  // used by the Home page activity preview where we already know which
  // bucket a row belongs to.
  status?: string | null;
  kind?: StatusKind;
  // Optional label override. Defaults to the bucket label ("Accepted"…)
  // when omitted; pass the raw server status to keep the exact wording
  // ("not_found", "partial", …).
  label?: ReactNode;
  // Extra CSS class for layout tweaks (e.g. .status-pill--inline on the
  // Recent Payments table where we want it to sit inside a small cell).
  className?: string;
}

export default function StatusPill({ status, kind, label, className }: Props) {
  const resolvedKind: StatusKind = kind ?? statusKindFor(status);
  const text = label ?? (status ?? KIND_LABEL[resolvedKind]);
  return (
    <span
      className={`status-pill status-pill--${resolvedKind}${className ? " " + className : ""}`}
      data-status={String(status ?? resolvedKind)}
    >
      <span className="status-pill__dot" aria-hidden="true" />
      <span className="status-pill__label">{text}</span>
    </span>
  );
}
