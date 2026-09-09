export type Ring = {
  ring: string; schedule: string | null; lastVerdict: string | null; lastEnded: string | null;
  state: 'active' | 'halted' | 'running'; runsToday: number; serves: string | null;
  emits: string[]; consumes: string[];
};
export type Fleet = { generated: string; rings: Ring[] };

export type ChainType = { type: string; items: number; outcome: boolean; producers: string[] };
export type Sink = { id: string; label: string | null; chain: ChainType[]; rings: string[] };
export type Goals = { apex: string | null; sinks: Sink[]; unserved: string[] };

export type TypeRow = {
  type: string; sink: string; outcome: boolean; items: number; ready: number; leased: number;
  accepted: number; rejected: number; dead: number; oldestReadySeconds: number | null; gated: boolean;
  subscribers: string[]; producers: string[];
};
export type Handoffs = { generated: string; types: TypeRow[] };

export type Event = {
  ts: string; kind: 'published' | 'accepted' | 'rejected' | 'dead' | 'run';
  ring: string; id: string | null; type: string | null; text: string;
};
export type Feed = { generated: string; events: Event[] };

export type Finding = { tag: string; text: string };
export type Doctor = { generated: string; rings: number; findings: Finding[] };

export type Delivery = { ring: string; state: string; attempts: number; created: string; ended: string | null; note: string | null };
export type TraceItem = {
  id: string; type: string; from: string; run: string; ts: string; key: string;
  cause: string | null; ref: string | null; sha256: string; payloadOk: boolean;
};
export type Trace = { item: TraceItem; receipt: string | null; deliveries: Delivery[]; cause: Trace | null; effects: Trace[] };

export class ApiError extends Error {}

export async function getJSON<T>(path: string, signal?: AbortSignal): Promise<T> {
  const res = await fetch(path, { signal, cache: 'no-store' });
  const text = await res.text();
  let body: unknown;
  try { body = JSON.parse(text); } catch { throw new ApiError(`${path}: not JSON`); }
  if (!res.ok) throw new ApiError((body as { error?: string }).error ?? `${path}: ${res.status}`);
  return body as T;
}
