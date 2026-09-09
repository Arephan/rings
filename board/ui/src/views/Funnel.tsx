import { usePoll } from '@/lib/poll';
import type { Goals } from '@/lib/api';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { Badge } from '@/components/ui/badge';
import { Loading, Nothing, Problem } from './bits';

export function FunnelView() {
  const { data, error } = usePoll<Goals>('/api/goals');
  if (error) return <Problem message={error} />;
  if (!data) return <Loading />;
  if (data.sinks.length === 0) return <Nothing title="No outcomes declared" hint="Write APEX, SINKS and CHAIN_<sink> in rings.conf." />;
  return (
    <div className="grid gap-4 md:grid-cols-2">
      {data.sinks.map((s) => (
        <Card key={s.id}>
          <CardHeader>
            <CardTitle className="text-base">{s.label ?? s.id}</CardTitle>
            <CardDescription className="font-mono text-xs">{s.id}</CardDescription>
          </CardHeader>
          <CardContent>
            {s.chain.length === 0 ? (
              <p className="text-sm text-muted-foreground">No chain declared. Rings serving it: {s.rings.join(', ') || 'none'}.</p>
            ) : (
              <Table>
                <TableHeader><TableRow><TableHead>Type</TableHead><TableHead className="text-right">Items</TableHead><TableHead>Producers</TableHead></TableRow></TableHeader>
                <TableBody>
                  {s.chain.map((c) => (
                    <TableRow key={c.type}>
                      <TableCell className="font-mono text-xs">
                        {c.type}{c.outcome && <Badge variant="default" className="ml-2 text-[10px]">outcome</Badge>}
                      </TableCell>
                      <TableCell className="text-right text-lg tabular-nums">{c.items}</TableCell>
                      <TableCell className="text-xs text-muted-foreground">{c.producers.join(', ') || <span className="text-destructive">no producer</span>}</TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            )}
            {s.rings.length > 0 && <p className="mt-3 text-xs text-muted-foreground">Also serving: {s.rings.join(', ')}</p>}
          </CardContent>
        </Card>
      ))}
      {data.unserved.length > 0 && (
        <Card className="border-destructive/40 md:col-span-2">
          <CardHeader><CardTitle className="text-base">Serving no stated outcome</CardTitle>
            <CardDescription>Give each a SERVES, put it on a chain, or stop paying for it.</CardDescription></CardHeader>
          <CardContent className="flex flex-wrap gap-2">{data.unserved.map((r) => <Badge key={r} variant="destructive">{r}</Badge>)}</CardContent>
        </Card>
      )}
    </div>
  );
}
