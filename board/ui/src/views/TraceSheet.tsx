import { useEffect, useState } from 'react';
import { getJSON, type Trace } from '@/lib/api';
import { ago, plural } from '@/lib/format';
import { Sheet, SheetContent, SheetDescription, SheetHeader, SheetTitle } from '@/components/ui/sheet';
import { Badge } from '@/components/ui/badge';
import { Separator } from '@/components/ui/separator';
import { ScrollArea } from '@/components/ui/scroll-area';
import { IdLink, Loading, Problem, StateBadge } from './bits';

function Node({ t, onOpen, depth = 0 }: { t: Trace; onOpen: (id: string) => void; depth?: number }) {
  return (
    <div className="space-y-2" style={{ marginLeft: depth ? 16 : 0 }}>
      <div className="flex flex-wrap items-center gap-2">
        <Badge variant="outline" className="font-mono text-[11px]">{t.item.type}</Badge>
        <IdLink id={t.item.id} onOpen={onOpen} />
        {!t.item.payloadOk && <Badge variant="destructive">payload checksum mismatch</Badge>}
      </div>
      <p className="text-xs text-muted-foreground">
        key <span className="font-mono">{t.item.key}</span> · from {t.item.from} · {ago(t.item.ts)}
        {t.item.ref && <> · ref <span className="font-mono break-all">{t.item.ref}</span></>}
      </p>
      {t.receipt && <p className="font-mono text-[11px] text-muted-foreground break-all">{t.receipt}</p>}
      <ul className="space-y-1">
        {t.deliveries.map((d) => (
          <li key={d.ring} className="flex flex-wrap items-center gap-2 text-sm">
            <span className="font-medium">{d.ring}</span><StateBadge state={d.state} />
            <span className="text-xs text-muted-foreground">
              {plural(d.attempts, 'silent attempt')}{d.ended ? `, ${ago(d.ended)}` : ''}
            </span>
            {d.note && <span className="text-xs">— {d.note}</span>}
          </li>
        ))}
        {t.deliveries.length === 0 && <li className="text-xs text-muted-foreground">no subscriber has a delivery record</li>}
      </ul>
      {t.effects.map((e) => <div key={e.item.id}><Separator className="my-2" /><Node t={e} onOpen={onOpen} depth={depth + 1} /></div>)}
    </div>
  );
}

// Walk up to the root so the sheet reads source → outcome.
function root(t: Trace): Trace {
  let r = t;
  while (r.cause) r = { ...r.cause, effects: [{ ...r, cause: null }] };
  return r;
}

export function TraceSheet({ id, onClose, onOpen }: { id: string | null; onClose: () => void; onOpen: (id: string) => void }) {
  const [t, setT] = useState<Trace | null>(null);
  const [err, setErr] = useState<string | null>(null);
  useEffect(() => {
    setT(null); setErr(null);
    if (!id) return;
    getJSON<Trace>(`/api/trace/${encodeURIComponent(id)}`).then(setT).catch((e) => setErr(String(e.message ?? e)));
  }, [id]);
  return (
    <Sheet open={!!id} onOpenChange={(o) => { if (!o) onClose(); }}>
      {/* The side variant sets its own max width, so the override has to match its specificity. */}
      <SheetContent className="w-full data-[side=right]:sm:max-w-xl">
        <SheetHeader className="pr-12">
          <SheetTitle className="font-mono text-sm break-all">{id}</SheetTitle>
          <SheetDescription>One item, source to outcome. Nothing here is cached.</SheetDescription>
        </SheetHeader>
        <ScrollArea className="min-h-0 flex-1">
          <div className="px-4 pb-4">
            {err ? <Problem message={err} /> : !t ? <Loading rows={6} /> : <Node t={root(t)} onOpen={onOpen} />}
          </div>
        </ScrollArea>
      </SheetContent>
    </Sheet>
  );
}
