import { StrictMode, type ComponentType } from "react";
import { createRoot, type Root } from "react-dom/client";
import { QueryClientProvider } from "@tanstack/react-query";

import { queryClient } from "@/lib/query";
import { Dashboard } from "@/views/Dashboard";
import { LibraryHealth } from "@/views/LibraryHealth";
import { Personas } from "@/views/Personas";
import { AutomationBuilder } from "@/views/AutomationBuilder";
import { SonicRadio } from "@/views/SonicRadio";

import "./styles.css";

// View registry — keys match the vanilla SPA's hash route names.
const VIEWS: Record<string, ComponentType> = {
  dashboard: Dashboard,
  "library-health": LibraryHealth,
  personas: Personas,
  "automation-builder": AutomationBuilder,
  "sonic-radio": SonicRadio,
};

// Per-container React roots so the host can host multiple React mount points
// (current shell only uses one but the contract is open).
const roots = new WeakMap<HTMLElement, Root>();

function mount(viewName: string, container: HTMLElement): void {
  const View = VIEWS[viewName];
  if (!View) {
    container.innerHTML = `<div style="padding:32px;color:#f87171">Unknown React view: ${viewName}</div>`;
    return;
  }
  let root = roots.get(container);
  if (!root) {
    root = createRoot(container);
    roots.set(container, root);
  }
  root.render(
    <StrictMode>
      <QueryClientProvider client={queryClient}>
        <View />
      </QueryClientProvider>
    </StrictMode>,
  );
}

function unmount(container: HTMLElement): void {
  const root = roots.get(container);
  if (root) {
    root.unmount();
    roots.delete(container);
  }
}

// Vite emits main.css as a sibling asset but the host loads our bundle via a
// dynamic ES-module import — no `<link>` is generated automatically. Inject one
// the first time the bundle runs so Tailwind utilities + glass tokens apply.
if (!document.querySelector('link[data-rs-react-css]')) {
  const link = document.createElement("link");
  link.rel = "stylesheet";
  link.href = "/static/react/assets/main.css";
  link.setAttribute("data-rs-react-css", "1");
  document.head.appendChild(link);
}

// Expose mount/unmount to the host SPA.
window.RoonSageReact = { mount, unmount };
window.dispatchEvent(new CustomEvent("roonsage:react-ready"));

// Dev mode: auto-mount based on hash so `npm run dev` shows something useful.
if (window.__RS_DEV__) {
  const devContainer = document.getElementById("rs-react-root");
  if (devContainer) {
    const hashView = window.location.hash.replace(/^#\/?/, "") || "dashboard";
    mount(hashView, devContainer);
    window.addEventListener("hashchange", () => {
      const next = window.location.hash.replace(/^#\/?/, "") || "dashboard";
      mount(next, devContainer);
    });
  }
}
