// context/KindleContext.tsx
import React, { createContext, useContext, useState, useEffect, ReactNode } from 'react';
import AsyncStorage from '@react-native-async-storage/async-storage';
import { KindleConfig } from '../kindle';

const STORAGE_KEY = '@kindle_bridge_config';

interface KindleContextValue {
  config: KindleConfig | null;
  setConfig: (cfg: KindleConfig | null) => void;
  loading: boolean;
}

const KindleContext = createContext<KindleContextValue>({
  config: null,
  setConfig: () => {},
  loading: true,
});

export function KindleProvider({ children }: { children: ReactNode }) {
  const [config, setConfigState] = useState<KindleConfig | null>(null);
  const [loading, setLoading] = useState(true);

  // Load saved config on startup
  useEffect(() => {
    async function load() {
      try {
        const raw = await AsyncStorage.getItem(STORAGE_KEY);
        if (raw) {
          const saved = JSON.parse(raw) as KindleConfig;
          setConfigState(saved);
        }
      } catch (e) {
        // ignore read errors — just start fresh
      } finally {
        setLoading(false);
      }
    }
    load();
  }, []);

  // Persist every time config changes
  async function setConfig(cfg: KindleConfig | null) {
    setConfigState(cfg);
    try {
      if (cfg) {
        await AsyncStorage.setItem(STORAGE_KEY, JSON.stringify(cfg));
      } else {
        await AsyncStorage.removeItem(STORAGE_KEY);
      }
    } catch (e) {
      // ignore write errors
    }
  }

  return (
    <KindleContext.Provider value={{ config, setConfig, loading }}>
      {children}
    </KindleContext.Provider>
  );
}

export function useKindle() {
  return useContext(KindleContext);
}