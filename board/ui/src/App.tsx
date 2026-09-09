import { useEffect, useState } from 'react';
import { Moon, Sun } from 'lucide-react';
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs';
import { Button } from '@/components/ui/button';
import { Separator } from '@/components/ui/separator';
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from '@/components/ui/tooltip';
import { usePoll } from '@/lib/poll';
import type { Goals } from '@/lib/api';
import { ago } from '@/lib/format';
import { FleetView } from '@/views/Fleet';
import { FunnelView } from '@/views/Funnel';
import { HandoffsView } from '@/views/HandoffsView';
import { FeedView } from '@/views/FeedView';
import { DoctorView } from '@/views/DoctorView';
import { TraceSheet } from '@/views/TraceSheet';

export default function App() {
  const [dark, setDark] = useState(() => window.matchMedia('(prefers-color-scheme: dark)').matches);
  const [trace, setTrace] = useState<string | null>(null);
  const goals = usePoll<Goals>('/api/goals');
  useEffect(() => { document.documentElement.classList.toggle('dark', dark); }, [dark]);
  // Until the first read lands, the apex is unknown — which is not the same as absent.
  const apex = goals.data ? (goals.data.apex ?? 'No apex stated. Write APEX in rings.conf.') : '';
  const read = goals.error ? 'not reading' : goals.at ? `read ${ago(new Date(goals.at).toISOString())}` : 'reading…';
  return (
    <TooltipProvider>
      <div className="min-h-screen bg-background text-foreground">
        <div className="mx-auto max-w-6xl px-6 py-8">
          <header className="mb-6 flex items-start justify-between gap-6">
            <div className="min-w-0">
              <h1 className="text-lg font-semibold tracking-tight">rings</h1>
              <p className="mt-0.5 min-h-5 text-sm">{apex}</p>
            </div>
            <div className="flex shrink-0 items-center gap-2">
              <Tooltip>
                <TooltipTrigger render={<span className="text-xs text-muted-foreground" />}>{read}</TooltipTrigger>
                <TooltipContent>Every number is re-read from the spool every 5 seconds. Nothing is cached.</TooltipContent>
              </Tooltip>
              <Button variant="ghost" size="icon" aria-label="Toggle theme" onClick={() => setDark(!dark)}>
                {dark ? <Sun className="h-4 w-4" /> : <Moon className="h-4 w-4" />}
              </Button>
            </div>
          </header>
          <Separator className="mb-6" />
          <Tabs defaultValue="fleet">
            <TabsList>
              <TabsTrigger value="fleet">Fleet</TabsTrigger>
              <TabsTrigger value="funnel">Funnel</TabsTrigger>
              <TabsTrigger value="handoffs">Handoffs</TabsTrigger>
              <TabsTrigger value="feed">Feed</TabsTrigger>
              <TabsTrigger value="doctor">Doctor</TabsTrigger>
            </TabsList>
            <TabsContent value="fleet" className="pt-4"><FleetView /></TabsContent>
            <TabsContent value="funnel" className="pt-4"><FunnelView /></TabsContent>
            <TabsContent value="handoffs" className="pt-4"><HandoffsView /></TabsContent>
            <TabsContent value="feed" className="pt-4"><FeedView onOpen={setTrace} /></TabsContent>
            <TabsContent value="doctor" className="pt-4"><DoctorView /></TabsContent>
          </Tabs>
          <TraceSheet id={trace} onClose={() => setTrace(null)} onOpen={setTrace} />
        </div>
      </div>
    </TooltipProvider>
  );
}
