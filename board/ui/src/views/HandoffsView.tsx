import { usePoll } from '@/lib/poll';
import type { Handoffs } from '@/lib/api';
import { duration } from '@/lib/format';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { Badge } from '@/components/ui/badge';
import { Tooltip, TooltipContent, TooltipTrigger } from '@/components/ui/tooltip';
import { Loading, Nothing, Problem } from './bits';

export function HandoffsView() {
  const { data, error } = usePoll<Handoffs>('/api/handoffs');
  if (error) return <Problem message={error} />;
  if (!data) return <Loading />;
  if (data.types.length === 0) return <Nothing title="No handoff types" hint="Declare CHAIN_<sink> in rings.conf." />;
  return (
    <Table>
      <TableHeader>
        <TableRow>
          <TableHead>Type</TableHead><TableHead>Sink</TableHead>
          <TableHead className="text-right">Items</TableHead><TableHead className="text-right">Ready</TableHead>
          <TableHead className="text-right">Leased</TableHead><TableHead className="text-right">Accepted</TableHead>
          <TableHead className="text-right">Rejected</TableHead><TableHead className="text-right">Dead</TableHead>
          <TableHead>Oldest ready</TableHead><TableHead>Subscribers</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {data.types.map((t) => (
          <TableRow key={t.type}>
            <TableCell className="font-mono text-xs">
              {t.type}
              {t.outcome && <Badge variant="default" className="ml-2 text-[10px]">outcome</Badge>}
              {!t.gated && (
                <Tooltip>
                  <TooltipTrigger render={<Badge variant="outline" className="ml-2 text-[10px]" />}>ungated</TooltipTrigger>
                  <TooltipContent>No accept.sh gate — items of this type are accepted on the producer's word alone.</TooltipContent>
                </Tooltip>
              )}
            </TableCell>
            <TableCell className="font-mono text-xs text-muted-foreground">{t.sink}</TableCell>
            <TableCell className="text-right tabular-nums">{t.items}</TableCell>
            <TableCell className="text-right tabular-nums">{t.ready}</TableCell>
            <TableCell className="text-right tabular-nums">{t.leased}</TableCell>
            <TableCell className="text-right tabular-nums">{t.accepted}</TableCell>
            <TableCell className="text-right tabular-nums">{t.rejected}</TableCell>
            <TableCell className="text-right tabular-nums">{t.dead > 0 ? <span className="text-destructive">{t.dead}</span> : t.dead}</TableCell>
            <TableCell className="text-xs text-muted-foreground">{duration(t.oldestReadySeconds)}</TableCell>
            <TableCell className="text-xs text-muted-foreground">{t.subscribers.join(', ') || '—'}</TableCell>
          </TableRow>
        ))}
      </TableBody>
    </Table>
  );
}
