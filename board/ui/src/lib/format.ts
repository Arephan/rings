export function ago(iso: string | null, now: number = Date.now()): string {
  if (!iso) return '—';
  const t = Date.parse(iso);
  if (Number.isNaN(t)) return '—';
  const s = Math.max(0, Math.floor((now - t) / 1000));
  if (s < 60) return 'just now';
  if (s < 3600) return `${Math.floor(s / 60)}m ago`;
  if (s < 86400) return `${Math.floor(s / 3600)}h ago`;
  return `${Math.floor(s / 86400)}d ago`;
}

// "1 finding", "2 findings" — a count the reader can read aloud.
export function plural(n: number, word: string): string {
  return `${n} ${word}${n === 1 ? '' : 's'}`;
}

// A feed line from the CLI opens with "<ring> <kind> …", and the row already states
// both: a badge for the kind, the ring in bold beside it. Drop that opening so the
// row says each thing once — but only when it is really there, so a line in any
// other shape still reads whole.
export function stripPrefix(text: string, ring: string, kind?: string | null): string {
  if (!ring || !kind) return text;
  const head = `${ring} ${kind}`;
  if (!text.startsWith(head)) return text;
  const rest = text.slice(head.length);
  if (rest.startsWith(' · ')) return rest.slice(3);
  if (rest.startsWith(' ')) return rest.slice(1);
  // "scoutful published …" is not "scout" followed by anything: leave it alone.
  return rest.length === 0 ? '' : text;
}

export function duration(seconds: number | null): string {
  if (seconds == null) return '—';
  if (seconds < 60) return `${seconds}s`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m`;
  if (seconds < 86400) return `${Math.floor(seconds / 3600)}h`;
  return `${Math.floor(seconds / 86400)}d`;
}
