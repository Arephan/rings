import { usePoll } from '@/lib/poll';
import type { Doctor } from '@/lib/api';
import { plural } from '@/lib/format';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { Badge } from '@/components/ui/badge';
import { Loading, Nothing, Problem } from './bits';

// The findings that cost something now, as the CLI tags them. The rest are
// things to tidy, and a page where half the rows are red is one nobody reads.
const DESTRUCTIVE_TAGS = new Set(['dead', 'silent', 'stuck', 'dead-letter', 'undelivered', 'invalid']);

export function DoctorView() {
  const { data, error } = usePoll<Doctor>('/api/doctor');
  // A failed poll is news about the reading, not about the fleet: say so above
  // the last answer instead of replacing it with the failure.
  if (!data) return error ? <Problem message={error} /> : <Loading />;
  // Nothing checked and nothing wrong are different sentences: an empty fleet has
  // not passed a check, it has not had one.
  const hint = data.rings === 0
    ? 'No rings to check yet.'
    : `Checked ${plural(data.rings, 'ring')} and found nothing to fix.`;
  return (
    <div>
      {error && <Problem message={error} />}
      {data.findings.length === 0 ? (
        <Nothing title="Nothing to report" hint={hint} />
      ) : (
        <>
          <p className="mb-3 text-sm text-muted-foreground">{plural(data.rings, 'ring')}, {plural(data.findings.length, 'finding')}</p>
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
        </>
      )}
    </div>
  );
}
