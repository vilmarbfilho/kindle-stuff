// screens/RemoteScreen.tsx
import React, { useState } from 'react';
import {
  View, Text, StyleSheet, TouchableOpacity, Alert,
} from 'react-native';
import { useKindle } from '../context/KindleContext';
import { sendCmd } from '../kindle';

type CmdButtonProps = {
  label: string;
  icon: string;
  cmd: string;
  onSend: (cmd: string) => void;
  loading: string | null;
  large?: boolean;
};

function CmdButton({ label, icon, cmd, onSend, loading, large }: CmdButtonProps) {
  const busy = loading === cmd;
  return (
    <TouchableOpacity
      style={[styles.cmdButton, large && styles.cmdButtonLarge, busy && styles.cmdButtonBusy]}
      onPress={() => onSend(cmd)}
      disabled={loading !== null}
    >
      <Text style={[styles.cmdIcon, large && styles.cmdIconLarge]}>{icon}</Text>
      <Text style={styles.cmdLabel}>{label}</Text>
    </TouchableOpacity>
  );
}

export default function RemoteScreen() {
  const { config } = useKindle();
  const [loading, setLoading] = useState<string | null>(null);
  const [lastCmd, setLastCmd] = useState('');

  async function send(cmd: string) {
    if (!config) return;
    setLoading(cmd);
    try {
      await sendCmd(config, cmd);
      setLastCmd(`${cmd} ✓`);
    } catch (e: any) {
      Alert.alert('Error', e.message);
    } finally {
      setLoading(null);
    }
  }

  return (
    <View style={styles.container}>
      <Text style={styles.title}>Remote Control</Text>
      <Text style={styles.subtitle}>Control your Kindle remotely</Text>

      {/* Main nav row */}
      <View style={styles.navRow}>
        <CmdButton icon="⏮" label="First" cmd="first_page" onSend={send} loading={loading} />
        <CmdButton icon="◀" label="Prev" cmd="prev_page" onSend={send} loading={loading} large />
        <CmdButton icon="▶" label="Next" cmd="next_page" onSend={send} loading={loading} large />
        <CmdButton icon="⏭" label="Last" cmd="last_page" onSend={send} loading={loading} />
      </View>

      {lastCmd ? (
        <Text style={styles.feedback}>{lastCmd}</Text>
      ) : null}

      <View style={styles.hint}>
        <Text style={styles.hintText}>
          Commands are sent to KOReader and executed immediately. Make sure a book is open on the Kindle.
        </Text>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#0f0f0f',
    padding: 24,
    alignItems: 'center',
    justifyContent: 'center',
  },
  title: {
    fontSize: 26,
    fontWeight: '700',
    color: '#fff',
    marginBottom: 6,
  },
  subtitle: {
    fontSize: 14,
    color: '#888',
    marginBottom: 40,
  },
  navRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 12,
    marginBottom: 24,
  },
  cmdButton: {
    backgroundColor: '#1c1c1e',
    borderRadius: 14,
    padding: 16,
    alignItems: 'center',
    minWidth: 64,
  },
  cmdButtonLarge: {
    backgroundColor: '#2563eb',
    padding: 24,
    minWidth: 80,
  },
  cmdButtonBusy: {
    opacity: 0.5,
  },
  cmdIcon: {
    fontSize: 24,
    marginBottom: 4,
  },
  cmdIconLarge: {
    fontSize: 32,
  },
  cmdLabel: {
    color: '#fff',
    fontSize: 11,
    fontWeight: '600',
  },
  feedback: {
    color: '#22c55e',
    fontSize: 14,
    marginBottom: 24,
  },
  hint: {
    backgroundColor: '#1c1c1e',
    borderRadius: 12,
    padding: 16,
    marginTop: 16,
  },
  hintText: {
    color: '#666',
    fontSize: 13,
    lineHeight: 19,
    textAlign: 'center',
  },
});
