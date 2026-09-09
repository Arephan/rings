import { usePoll } from '@/lib/poll';
import type { Fleet } from '@/lib/api';
import { ago } from '@/lib/format';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { Badge } from '@/components/ui/badge';
import { Loading, Nothing, Problem, StateBadge } from './bits';

export function FleetView() {
  const { data, error } = usePoll<Fleet>('/api/fleet');
  if (error) return <Problem message={error} />;
  if (!data) return <Loading />;
  if (data.rings.length === 0) return <Nothing title="No rings" hint="rings new <name>, or rings demo to see one working." />;
  return (
    <Table>
      <TableHeader>
        <TableRow>
          <TableHead>Ring</TableHead><TableHead>State</TableHead><TableHead>Schedule</TableHead>
          <TableHead>Last run</TableHead><TableHead className="text-right">Today</TableHead>
          <TableHead>Consumes</TableHead><TableHead>Emits</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {data.rings.map((r) => (
          <TableRow key={r.ring}>
            <TableCell className="font-medium">{r.ring}</TableCell>
            <TableCell><StateBadge state={r.state} /></TableCell>
            <TableCell className="font-mono text-xs text-muted-foreground">{r.schedule ?? '—'}</TableCell>
            <TableCell className="whitespace-nowrap">
              <StateBadge state={r.lastVerdict} />{' '}
              <span className="text-xs text-muted-foreground">{ago(r.lastEnded)}</span>
            </TableCell>
            <TableCell className="text-right tabular-nums">{r.runsToday}</TableCell>
            <TableCell className="space-x-1">{r.consumes.map((t) => <Badge key={t} variant="outline" className="font-mono text-[11px]">{t}</Badge>)}</TableCell>
            <TableCell className="space-x-1">{r.emits.map((t) => <Badge key={t} variant="outline" className="font-mono text-[11px]">{t}</Badge>)}</TableCell>
          </TableRow>
        ))}
      </TableBody>
    </Table>
  );
}
