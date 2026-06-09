/*
 * Thin fetch wrapper. Mirrors the contract of frontend/modules/api.js::apiCall:
 * - Base URL `/api`
 * - Throws RoonSageApiError on non-2xx with parsed detail
 * - Honours the HTTP Basic Auth header injected by the vanilla SPA at the
 *   browser level (credentials: "same-origin")
 */

export class RoonSageApiError extends Error {
  status: number;
  detail: unknown;
  constructor(message: string, status: number, detail?: unknown) {
    super(message);
    this.name = "RoonSageApiError";
    this.status = status;
    this.detail = detail;
  }
}

type ApiInit = Omit<RequestInit, "body"> & { json?: unknown };

export async function api<T = unknown>(path: string, init: ApiInit = {}): Promise<T> {
  const { json, headers, ...rest } = init;
  const url = path.startsWith("/api") ? path : `/api${path.startsWith("/") ? path : `/${path}`}`;

  const finalHeaders: HeadersInit = {
    Accept: "application/json",
    ...(json !== undefined ? { "Content-Type": "application/json" } : {}),
    ...(headers ?? {}),
  };

  const res = await fetch(url, {
    credentials: "same-origin",
    ...rest,
    headers: finalHeaders,
    body: json !== undefined ? JSON.stringify(json) : (rest as RequestInit).body,
  });

  if (!res.ok) {
    let detail: unknown = undefined;
    try {
      detail = await res.clone().json();
    } catch {
      try {
        detail = await res.text();
      } catch {
        /* ignore */
      }
    }
    const msg =
      (typeof detail === "object" && detail !== null && "detail" in detail
        ? String((detail as { detail: unknown }).detail)
        : null) ?? `${res.status} ${res.statusText}`;
    throw new RoonSageApiError(msg, res.status, detail);
  }

  const ctype = res.headers.get("content-type") ?? "";
  if (ctype.includes("application/json")) {
    return (await res.json()) as T;
  }
  return (await res.text()) as unknown as T;
}
