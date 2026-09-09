import { useEffect, useState } from 'react';
import { getJSON } from './api';

export function usePoll<T>(path: string, ms = 5000) {
  const [data, setData] = useState<T | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [at, setAt] = useState<number | null>(null);
  useEffect(() => {
    let live = true;
    let inFlight = false;
    const ctl = new AbortController();
    const tick = async () => {
      // One read at a time per path. The CLI is the query layer, and on a big spool a
      // command can outlast the interval; a second tick would only start a second
      // subprocess to answer the same question. Skip it and wait for the one in flight.
      if (inFlight) return;
      inFlight = true;
      try {
        const d = await getJSON<T>(path, ctl.signal);
        if (!live) return;
        setData(d); setError(null); setAt(Date.now());
      } catch (e) {
        if (live && !(e instanceof DOMException)) setError(String((e as Error).message ?? e));
      } finally {
        inFlight = false;
      }
    };
    tick();
    const t = setInterval(tick, ms);
    return () => { live = false; ctl.abort(); clearInterval(t); };
  }, [path, ms]);
  return { data, error, at };
}
