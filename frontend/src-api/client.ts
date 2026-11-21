// Fetch wrapper for the Lambda Cloud API (/api/v1) and the console-internal API (/internal/v1).
// Both use the same envelope: success `{data}`, failure `{error: {code, message, suggestion}}`.
// Auth: the browser never holds the console key. Calls are same-origin with no Authorization header;
// the reverse proxy (nginx in the image, vite in dev) injects the console key server-side. Callers that
// pass their own `authorization` (e.g. a playground using a user's API key) keep it.
import type { components as Internal } from './schema/internal'

export type Session = { account: { id: string; name: string }; user: Internal['schemas']['AccountUser']; mode: 'live' | 'mock' }

/** A mutation refused because the caller's key lacks admin rights (adapter: 403 global/forbidden). */
export function isForbidden(e: unknown): boolean {
  return e instanceof ApiError && (e.code === 'global/forbidden' || (e.status === 403 && e.method !== 'GET'))
}

export class ApiError extends Error {
  readonly code: string
  readonly suggestion?: string
  readonly status: number
  /** HTTP method of the failed request (set by api()). */
  method = 'GET'
  constructor(status: number, code: string, message: string, suggestion?: string) {
    super(message)
    this.name = 'ApiError'
    this.status = status
    this.code = code
    this.suggestion = suggestion
  }
}

async function parse<T>(res: Response, onBody?: (body: unknown) => void): Promise<T> {
  const text = await res.text()
  let body: unknown
  try {
    body = text ? JSON.parse(text) : {}
    onBody?.(body)
  } catch {
    throw new ApiError(res.status, 'global/unreachable', res.ok ? 'Unexpected response from the API.' : `The API is unavailable (HTTP ${res.status}).`)
  }
  const b = body as { data?: T; error?: { code?: string; message?: string; suggestion?: string } }
  if (!res.ok || b.error) {
    const e = b.error ?? {}
    throw new ApiError(res.status, e.code ?? 'global/unknown', e.message ?? `Request failed (HTTP ${res.status}).`, e.suggestion)
  }
  return b.data as T
}

// Every console call carries X-Lambda-Console: 1. nginx only adds the console key to requests with it,
// and a cross-site page can't send a custom header without a CORS preflight, which nginx never approves.
async function send(url: string, init?: RequestInit): Promise<Response> {
  try {
    const headers = new Headers(init?.headers)
    headers.set('X-Lambda-Console', '1')
    return await fetch(url, { ...init, headers })
  } catch {
    throw new ApiError(0, 'global/unreachable', 'The API is unreachable. Check that lambda-api-mock is running.')
  }
}

let sessionPromise: Promise<Session> | null = null

/** The signed-in demo session; fetched once, retried on the next call if it failed. */
export function getSession(): Promise<Session> {
  if (!sessionPromise) {
    sessionPromise = send('/internal/v1/session').then((r) => parse<Session>(r))
    sessionPromise.catch(() => {
      sessionPromise = null
    })
  }
  return sessionPromise
}

/** One request/response as the UI sent it; rendered as the equivalent public API call (ApiCall.tsx). */
export type Exchange = {
  method: string
  path: string
  body?: unknown
  status: number
  response?: unknown
  at: number
}

// Latest GET per path, so a page can list the reads it was rendered from ("View API"), and the latest
// write, so a page can show the call behind the action just taken even after its modal closed.
const reads = new Map<string, Exchange>()
let readList: Exchange[] = []
let lastWrite: Exchange | null = null
const listeners = new Set<() => void>()
export function recordedReads(): Exchange[] {
  return readList
}
export function recordedWrite(): Exchange | null {
  return lastWrite
}
export function subscribeReads(fn: () => void): () => void {
  listeners.add(fn)
  return () => listeners.delete(fn)
}

export async function api<T>(
  path: string,
  init: { method?: string; body?: unknown; authorization?: string; record?: (e: Exchange) => void } = {},
): Promise<T> {
  const method = init.method ?? 'GET'
  const headers: Record<string, string> = { Accept: 'application/json' }
  if (init.authorization) headers.Authorization = init.authorization
  if (init.body !== undefined) headers['Content-Type'] = 'application/json'
  const res = await send(path, {
    credentials: 'same-origin',
    method,
    headers,
    body: init.body === undefined ? undefined : JSON.stringify(init.body),
  })
  const exchange: Exchange = { method, path, body: init.body, status: res.status, at: Date.now() }
  const done = () => {
    init.record?.(exchange)
    if (method === 'GET') {
      reads.set(path, exchange)
      readList = [...reads.values()]
    } else {
      lastWrite = exchange
    }
    listeners.forEach((l) => l())
  }
  try {
    return await parse<T>(res, (b) => (exchange.response = b))
  } catch (e) {
    if (e instanceof ApiError) e.method = method
    throw e
  } finally {
    done()
  }
}
