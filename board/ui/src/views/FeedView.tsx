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

function Row({ e, onOpen }: { e: Event; onOpen: (id: string) => void }) {
  return (
    <div className="flex flex-wrap items-baseline gap-2 border-b py-2 text-sm last:border-0">
      <Tooltip>
        <TooltipTrigger render={<span className="w-24 shrink-0 font-mono text-xs text-muted-foreground" />}>
          {ago(e.ts)}
        </TooltipTrigger>
        <TooltipContent>{e.ts}</TooltipContent>
      </Tooltip>
      <StateBadge state={e.kind} />
      <span className="font-medium">{e.ring}</span>
      <span className="text-muted-foreground">{withIdLink(e.text, e.id, onOpen)}</span>
    </div>
  );
}

export function FeedView({ onOpen }: { onOpen: (id: string) => void }) {
  const { data, error } = usePoll<Feed>('/api/feed?n=200');
  if (error) return <Problem message={error} />;
  if (!data) return <Loading />;
  if (data.events.length === 0) return <Nothing title="Nothing has happened yet" hint="rings demo" />;
  return (
    <ScrollArea className="h-[70vh]">
      <div className="pr-4">
        {data.events.map((e, i) => <Row key={`${e.ts}-${i}`} e={e} onOpen={onOpen} />)}
      </div>
    </ScrollArea>
  );
}
