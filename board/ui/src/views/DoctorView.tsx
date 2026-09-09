import { usePoll } from '@/lib/poll';
import type { Doctor } from '@/lib/api';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { Badge } from '@/components/ui/badge';
import { Loading, Nothing, Problem } from './bits';

const DESTRUCTIVE_TAGS = new Set(['dead', 'dead-letter', 'stuck', 'undelivered']);

export function DoctorView() {
  const { data, error } = usePoll<Doctor>('/api/doctor');
  if (error) return <Problem message={error} />;
  if (!data) return <Loading />;
  if (data.findings.length === 0) return <Nothing title="Nothing to report" hint={`${data.rings} rings checked, no findings.`} />;
  return (
    <div>
      <p className="mb-3 text-sm text-muted-foreground">{data.rings} rings, {data.findings.length} findings</p>
      <Table>
        <TableHeader><TableRow><TableHead>Tag</TableHead><TableHead>Finding</TableHead></TableRow></TableHeader>
        <TableBody>
          {data.findings.map((f, i) => (
            <TableRow key={i}>
              <TableCell>
                <Badge variant={DESTRUCTIVE_TAGS.has(f.tag) ? 'destructive' : 'outline'} className="font-mono text-[11px]">{f.tag}</Badge>
              </TableCell>
              <TableCell className="text-sm">{f.text}</TableCell>
            </TableRow>
          ))}
        </TableBody>
      </Table>
    </div>
  );
}
