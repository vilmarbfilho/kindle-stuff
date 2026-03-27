// screens/DashboardScreen.tsx
import React, { useEffect, useState, useCallback } from 'react';
import {
  View, Text, StyleSheet, TouchableOpacity,
  ScrollView, RefreshControl,
} from 'react-native';
import { useKindle } from '../context/KindleContext';
import { openEventStream, getProgress, Progress } from '../kindle';

export default function DashboardScreen() {
  const { config, setConfig } = useKindle();
  const [progress, setProgress] = useState<Progress | null>(null);
  const [connected, setConnected] = useState(false);
  const [lastEvent, setLastEvent] = useState('');
  const [refreshing, setRefreshing] = useState(false);

  useEffect(() => {
    if (!config) return;
    setConnected(false);

    const stop = openEventStream(
      config,
      (p) => {
        setProgress(p);
        setConnected(true);
        setLastEvent(new Date().toLocaleTimeString());
      },
      (_err) => {
        setConnected(false);
      },
    );

    return stop;
  }, [config]);

  const onRefresh = useCallback(async () => {
    if (!config) return;
    setRefreshing(true);
    try {
      const p = await getProgress(config);
      setProgress(p);
      setLastEvent(new Date().toLocaleTimeString());
    } finally {
      setRefreshing(false);
    }
  }, [config]);

  const percent = progress?.percent ?? 0;
  const hasBook = progress && progress.title !== 'No book open';

  return (
    <ScrollView
      style={styles.container}
      contentContainerStyle={styles.content}
      refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} tintColor="#60a5fa" />}
    >
      {/* Connection status */}
      <View style={styles.statusRow}>
        <View style={[styles.dot, { backgroundColor: connected ? '#22c55e' : '#ef4444' }]} />
        <Text style={styles.statusText}>
          {connected ? `Live  ·  ${config?.ip}` : 'Connecting...'}
        </Text>
        <TouchableOpacity onPress={() => setConfig(null)}>
          <Text style={styles.disconnectText}>Disconnect</Text>
        </TouchableOpacity>
      </View>

      {/* Book card */}
      <View style={styles.card}>
        {hasBook ? (
          <>
            <Text style={styles.bookTitle} numberOfLines={3}>{progress.title}</Text>
            {progress.authors ? (
              <Text style={styles.bookAuthors}>{progress.authors}</Text>
            ) : null}

            {/* Progress bar */}
            <View style={styles.progressBarBg}>
              <View style={[styles.progressBarFill, { width: `${percent}%` }]} />
            </View>

            <View style={styles.statsRow}>
              <Stat label="Page" value={String(progress.page)} />
              <Stat label="Total" value={String(progress.total)} />
              <Stat label="Progress" value={`${percent}%`} />
            </View>

            {progress.file ? (
              <Text style={styles.filePath} numberOfLines={1}>{progress.file}</Text>
            ) : null}
          </>
        ) : (
          <View style={styles.noBook}>
            <Text style={styles.noBookIcon}>📖</Text>
            <Text style={styles.noBookText}>No book open</Text>
            <Text style={styles.noBookSub}>Open a book in KOReader to see progress here</Text>
          </View>
        )}
      </View>

      {lastEvent ? (
        <Text style={styles.lastEvent}>Last update: {lastEvent}</Text>
      ) : null}
    </ScrollView>
  );
}

function Stat({ label, value }: { label: string; value: string }) {
  return (
    <View style={styles.stat}>
      <Text style={styles.statValue}>{value}</Text>
      <Text style={styles.statLabel}>{label}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: '#0f0f0f' },
  content: { padding: 20 },
  statusRow: {
    flexDirection: 'row',
    alignItems: 'center',
    marginBottom: 20,
  },
  dot: {
    width: 8,
    height: 8,
    borderRadius: 4,
    marginRight: 8,
  },
  statusText: { flex: 1, color: '#888', fontSize: 13 },
  disconnectText: { color: '#ef4444', fontSize: 13 },
  card: {
    backgroundColor: '#1c1c1e',
    borderRadius: 16,
    padding: 20,
    marginBottom: 16,
  },
  bookTitle: {
    fontSize: 22,
    fontWeight: '700',
    color: '#fff',
    marginBottom: 6,
    lineHeight: 28,
  },
  bookAuthors: {
    fontSize: 14,
    color: '#888',
    marginBottom: 20,
  },
  progressBarBg: {
    height: 6,
    backgroundColor: '#2c2c2e',
    borderRadius: 3,
    marginBottom: 16,
    overflow: 'hidden',
  },
  progressBarFill: {
    height: '100%',
    backgroundColor: '#2563eb',
    borderRadius: 3,
  },
  statsRow: {
    flexDirection: 'row',
    justifyContent: 'space-around',
    marginBottom: 16,
  },
  stat: { alignItems: 'center' },
  statValue: { fontSize: 22, fontWeight: '700', color: '#fff' },
  statLabel: { fontSize: 12, color: '#888', marginTop: 2 },
  filePath: {
    fontSize: 11,
    color: '#555',
    marginTop: 4,
  },
  noBook: { alignItems: 'center', paddingVertical: 24 },
  noBookIcon: { fontSize: 48, marginBottom: 12 },
  noBookText: { fontSize: 18, fontWeight: '600', color: '#fff', marginBottom: 6 },
  noBookSub: { fontSize: 14, color: '#888', textAlign: 'center' },
  lastEvent: { textAlign: 'center', color: '#444', fontSize: 12 },
});
