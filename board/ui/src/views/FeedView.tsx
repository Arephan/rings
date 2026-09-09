import type { ReactNode } from 'react';
import { usePoll } from '@/lib/poll';
import type { Event, Feed } from '@/lib/api';
import { ago } from '@/lib/format';
import { ScrollArea } from '@/components/ui/scroll-area';
import { Tooltip, TooltipContent, TooltipTrigger } from '@/components/ui/tooltip';
import { IdLink, Loading, Nothing, Problem, StateBadge } from './bits';

function withIdLink(text: string, id: string | null, onOpen: (id: string) => void): ReactNode {
  if (!id) return text;
  const parts = text.split(id);
  if (parts.length < 2) return text;
  return parts.flatMap((part, i) => (i === 0 ? [part] : [<IdLink key={i} id={id} onOpen={onOpen} />, part]));
}

// Time in a fixed column, everything else in one block that wraps within itself,
// so a long line runs on under its own first word instead of under the clock.
function Row({ e, onOpen }: { e: Event; onOpen: (id: string) => void }) {
  return (
    <div className="flex items-baseline gap-3 border-b py-2 text-sm last:border-0">
      <Tooltip>
        <TooltipTrigger render={<span className="w-16 shrink-0 font-mono text-xs text-muted-foreground" />}>
          {ago(e.ts)}
        </TooltipTrigger>
        <TooltipContent>{e.ts}</TooltipContent>
      </Tooltip>
      <div className="min-w-0 flex-1">
        <StateBadge state={e.kind} />{' '}
        <span className="font-medium">{e.ring}</span>{' '}
        {/* A run's id names a run, not an item, and nothing can trace it: leave it as text. */}
        <span className="text-muted-foreground">{withIdLink(e.text, e.type ? e.id : null, onOpen)}</span>
      </div>
    </div>
  );
}

export function FeedView({ onOpen }: { onOpen: (id: string) => void }) {
  const { data, error } = usePoll<Feed>('/api/feed?n=200');
  if (error) return <Problem message={error} />;
  if (!data) return <Loading />;
  if (data.events.length === 0) {
    return <Nothing title="Nothing has happened yet" hint="Run a ring — or rings demo — and every run, handoff and refusal lands here." />;
  }
  // Sized off the viewport so the list scrolls inside itself and the page never does.
  return (
    <ScrollArea className="h-[calc(100dvh-18rem)] min-h-64">
      <div className="pr-4">
        {data.events.map((e, i) => <Row key={`${e.ts}-${i}`} e={e} onOpen={onOpen} />)}
      </div>
    </ScrollArea>
  );
}
