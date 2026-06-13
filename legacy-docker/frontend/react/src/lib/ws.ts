/*
 * Thin WebSocket client. Shares one connection per channel for the lifetime
 * of the React bundle; views subscribe via `useChannel(channel, onMessage)`.
 *
 * Channels are matched on the backend by URL: /ws/<channel>. Auto-reconnect
 * with exponential back-off, capped at 30s.
 */

import { useEffect, useRef } from "react";

type Channel =
  | "enrichment"
  | "audio_features"
  | "clustering"
  | "sync"
  | "automations"
  | "dashboard";

type Listener = (data: unknown) => void;

const sockets = new Map<Channel, WebSocket>();
const listeners = new Map<Channel, Set<Listener>>();
const backoffs = new Map<Channel, number>();

function wsUrl(channel: Channel): string {
  const proto = window.location.protocol === "https:" ? "wss" : "ws";
  return `${proto}://${window.location.host}/ws/${channel}`;
}

function open(channel: Channel) {
  const existing = sockets.get(channel);
  if (existing && existing.readyState <= WebSocket.OPEN) return existing;

  const ws = new WebSocket(wsUrl(channel));
  sockets.set(channel, ws);
  ws.addEventListener("message", (ev) => {
    const set = listeners.get(channel);
    if (!set) return;
    let data: unknown = ev.data;
    try {
      data = JSON.parse(ev.data);
    } catch {
      /* keep as string */
    }
    set.forEach((cb) => cb(data));
  });
  ws.addEventListener("close", () => {
    sockets.delete(channel);
    const wait = Math.min(30_000, 1_000 * 2 ** (backoffs.get(channel) ?? 0));
    backoffs.set(channel, (backoffs.get(channel) ?? 0) + 1);
    if (listeners.get(channel)?.size) {
      setTimeout(() => open(channel), wait);
    }
  });
  ws.addEventListener("open", () => {
    backoffs.set(channel, 0);
  });
  return ws;
}

export function subscribe(channel: Channel, cb: Listener): () => void {
  let set = listeners.get(channel);
  if (!set) {
    set = new Set();
    listeners.set(channel, set);
  }
  set.add(cb);
  open(channel);
  return () => {
    const s = listeners.get(channel);
    s?.delete(cb);
    if (s && s.size === 0) {
      sockets.get(channel)?.close();
      sockets.delete(channel);
    }
  };
}

export function useChannel(channel: Channel, cb: Listener): void {
  // Keep the listener in a ref so the effect doesn't re-subscribe (and thus
  // tear down / reopen the underlying WebSocket) on every render.
  const ref = useRef(cb);
  ref.current = cb;
  useEffect(
    () => subscribe(channel, (data) => ref.current(data)),
    [channel],
  );
}
