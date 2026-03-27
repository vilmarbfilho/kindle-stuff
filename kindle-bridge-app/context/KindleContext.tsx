// context/KindleContext.tsx
import React, { createContext, useContext, useState, ReactNode } from 'react';
import { KindleConfig } from '../kindle';

interface KindleContextValue {
  config: KindleConfig | null;
  setConfig: (cfg: KindleConfig | null) => void;
}

const KindleContext = createContext<KindleContextValue>({
  config: null,
  setConfig: () => {},
});

export function KindleProvider({ children }: { children: ReactNode }) {
  const [config, setConfig] = useState<KindleConfig | null>(null);
  return (
    <KindleContext.Provider value={{ config, setConfig }}>
      {children}
    </KindleContext.Provider>
  );
}

export function useKindle() {
  return useContext(KindleContext);
}
