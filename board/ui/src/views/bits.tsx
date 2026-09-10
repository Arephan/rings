import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Skeleton } from '@/components/ui/skeleton';
import { Empty, EmptyDescription, EmptyHeader, EmptyTitle } from '@/components/ui/empty';

const VARIANT: Record<string, 'default' | 'secondary' | 'destructive' | 'outline'> = {
  active: 'secondary', running: 'default', halted: 'outline',
  pass: 'secondary', unverified: 'destructive', error: 'destructive', timeout: 'destructive',
  ready: 'outline', leased: 'default', accepted: 'secondary', rejected: 'destructive', dead: 'destructive',
  published: 'secondary', run: 'outline',
};

export function StateBadge({ state }: { state: string | null }) {
  if (!state) return <span className="text-muted-foreground">—</span>;
  return <Badge variant={VARIANT[state] ?? 'outline'} className="font-mono text-[11px]">{state}</Badge>;
}

// A zero is the absence of something, not a measurement of it: keep it quiet so
// the numbers that are not zero are the ones the eye lands on.
export function Count({ n }: { n: number }) {
  return <span className={n === 0 ? 'text-muted-foreground' : undefined}>{n}</span>;
}

export function IdLink({ id, onOpen }: { id: string; onOpen: (id: string) => void }) {
  return (
    <Button variant="link" size="sm" className="h-auto p-0 font-mono text-[12px]" onClick={() => onOpen(id)} title={id}>
      <span className="inline-block max-w-[16rem] truncate align-bottom">{id}</span>
    </Button>
  );
}

export function Loading({ rows = 4 }: { rows?: number }) {
  return (
    <div className="space-y-2 py-2">
      {Array.from({ length: rows }, (_, i) => <Skeleton key={i} className="h-8 w-full" />)}
    </div>
  );
}

export function Problem({ message }: { message: string }) {
  return (
    <div className="flex items-center gap-3 py-6">
      <Badge variant="destructive">error</Badge>
      <span className="text-sm text-muted-foreground">{message}</span>
    </div>
  );
}

export function Nothing({ title, hint }: { title: string; hint: string }) {
  return (
    <Empty className="py-10">
      <EmptyHeader>
        <EmptyTitle className="text-base">{title}</EmptyTitle>
        <EmptyDescription>{hint}</EmptyDescription>
      </EmptyHeader>
    </Empty>
  );
}
