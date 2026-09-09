import { useState } from 'react';
import { Button } from '@/components/ui/button';

function App() {
  const [count, setCount] = useState(0);

  return (
    <div className="flex min-h-svh flex-col items-center justify-center gap-4">
      <h1 className="text-2xl font-semibold">rings</h1>
      <Button onClick={() => setCount((c) => c + 1)}>Count is {count}</Button>
    </div>
  );
}

export default App;
