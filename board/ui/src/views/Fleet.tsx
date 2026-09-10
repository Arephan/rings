import { usePoll } from '@/lib/poll';
import type { Fleet } from '@/lib/api';
import { ago } from '@/lib/format';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { Badge } from '@/components/ui/badge';
import { Count, Loading, Nothing, Problem, StateBadge } from './bits';

function Types({ types }: { types: string[] }) {
  if (types.length === 0) return <span className="text-muted-foreground">—</span>;
  return types.map((t) => <Badge key={t} variant="outline" className="font-mono text-[11px]">{t}</Badge>);
}

export function FleetView() {
  const { data, error } = usePoll<Fleet>('/api/fleet');
  // A failed poll is news about the reading, not about the fleet: say so above
  // the last answer instead of replacing it with the failure.
  if (!data) return error ? <Problem message={error} /> : <Loading />;
  return (
    <>
      {error && <Problem message={error} />}
      {data.rings.length === 0 ? (
        <Nothing title="No rings" hint="rings new <name>, or rings demo to see one working." />
      ) : (
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
                  {r.lastEnded === null && r.lastVerdict === null ? (
                    <span className="text-muted-foreground">never run</span>
                  ) : (
                    <>
                      <StateBadge state={r.lastVerdict} />{' '}
                      <span className="text-xs text-muted-foreground">{ago(r.lastEnded)}</span>
                    </>
                  )}
                </TableCell>
                <TableCell className="text-right tabular-nums"><Count n={r.runsToday} /></TableCell>
                <TableCell className="space-x-1"><Types types={r.consumes} /></TableCell>
                <TableCell className="space-x-1"><Types types={r.emits} /></TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      )}
    </>
  );
}
