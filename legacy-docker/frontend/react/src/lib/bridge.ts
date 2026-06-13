/*
 * Bridge between the React microfrontend and the vanilla SPA host.
 *
 * The vanilla app exposes a global `window.rsState` object plus `apiCall` and
 * a `state` event emitter. This module wraps those into typed hooks so React
 * code never reaches into `window.*` directly.
 */

import { useEffect, useState } from "react";

declare global {
  interface Window {
    rsState?: Record<string, unknown>;
    ROONSAGE_VERSION?: string;
    __RS_DEV__?: boolean;
    RoonSageReact?: {
      mount: (view: string, container: HTMLElement) => void;
      unmount: (container: HTMLElement) => void;
    };
  }
}

export type ZoneSummary = {
  zone_id: string;
  display_name: string;
  state: "playing" | "paused" | "stopped" | "loading";
};

/** Read the currently active Roon zone ID from the vanilla state, with fallback. */
export function getActiveZoneId(): string | null {
  try {
    const fromLs = localStorage.getItem("rs-zone-id");
    if (fromLs) return fromLs;
    const rs = window.rsState as { activeZone?: { zone_id?: string } } | undefined;
    return rs?.activeZone?.zone_id ?? null;
  } catch {
    return null;
  }
}

/** React hook — re-renders when the vanilla SPA dispatches a `roonsage:zone` event. */
export function useActiveZoneId(): string | null {
  const [zoneId, setZoneId] = useState<string | null>(getActiveZoneId);
  useEffect(() => {
    const handler = () => setZoneId(getActiveZoneId());
    window.addEventListener("roonsage:zone", handler);
    window.addEventListener("storage", handler);
    return () => {
      window.removeEventListener("roonsage:zone", handler);
      window.removeEventListener("storage", handler);
    };
  }, []);
  return zoneId;
}

/** Trigger a vanilla SPA navigation (updates URL hash + main view). */
export function navigateToHashView(hash: string): void {
  window.location.hash = hash.startsWith("#") ? hash : `#${hash}`;
}

/** Show a toast via the vanilla SPA's toast system. Falls back to console. */
export function showToast(message: string, kind: "info" | "success" | "error" = "info"): void {
  const detail = { message, kind };
  window.dispatchEvent(new CustomEvent("roonsage:toast", { detail }));
  if (window.__RS_DEV__) console.log(`[toast:${kind}]`, message);
}

export function getAppVersion(): string {
  return window.ROONSAGE_VERSION ?? "dev";
}
