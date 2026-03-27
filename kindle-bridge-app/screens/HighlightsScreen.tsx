// screens/HighlightsScreen.tsx
import React, { useState, useCallback } from 'react';
import {
  View, Text, StyleSheet, FlatList,
  TouchableOpacity, ActivityIndicator, RefreshControl,
} from 'react-native';
import { useKindle } from '../context/KindleContext';
import { getHighlights, Highlight } from '../kindle';

export default function HighlightsScreen() {
  const { config } = useKindle();
  const [highlights, setHighlights] = useState<Highlight[]>([]);
  const [title, setTitle] = useState('');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');
  const [loaded, setLoaded] = useState(false);

  const load = useCallback(async () => {
    if (!config) return;
    setLoading(true);
    setError('');
    try {
      const res = await getHighlights(config);
      if (res.error) {
        setError(res.error);
        setHighlights([]);
      } else {
        setTitle(res.title ?? '');
        setHighlights(res.highlights ?? []);
      }
      setLoaded(true);
    } catch (e: any) {
      setError(e.message);
    } finally {
      setLoading(false);
    }
  }, [config]);

  if (!loaded && !loading) {
    return (
      <View style={styles.center}>
        <Text style={styles.emptyIcon}>🔖</Text>
        <Text style={styles.emptyTitle}>Highlights</Text>
        <Text style={styles.emptyDesc}>
          Fetch highlights from the currently open book in KOReader.
        </Text>
        <TouchableOpacity style={styles.button} onPress={load}>
          <Text style={styles.buttonText}>Load Highlights</Text>
        </TouchableOpacity>
      </View>
    );
  }

  if (loading) {
    return (
      <View style={styles.center}>
        <ActivityIndicator size="large" color="#2563eb" />
        <Text style={styles.loadingText}>Loading highlights...</Text>
      </View>
    );
  }

  if (error) {
    return (
      <View style={styles.center}>
        <Text style={styles.errorIcon}>⚠️</Text>
        <Text style={styles.errorText}>{error}</Text>
        <TouchableOpacity style={styles.button} onPress={load}>
          <Text style={styles.buttonText}>Try Again</Text>
        </TouchableOpacity>
      </View>
    );
  }

  return (
    <FlatList
      style={styles.container}
      data={highlights}
      keyExtractor={(_, i) => String(i)}
      refreshControl={<RefreshControl refreshing={loading} onRefresh={load} tintColor="#60a5fa" />}
      ListHeaderComponent={
        <View style={styles.header}>
          <Text style={styles.bookTitle}>{title}</Text>
          <Text style={styles.count}>{highlights.length} highlight{highlights.length !== 1 ? 's' : ''}</Text>
        </View>
      }
      ListEmptyComponent={
        <View style={styles.center}>
          <Text style={styles.emptyDesc}>No highlights found for this book yet.</Text>
        </View>
      }
      renderItem={({ item, index }) => (
        <View style={styles.card}>
          <Text style={styles.highlightText}>"{item.text}"</Text>
          <View style={styles.meta}>
            {item.chapter ? <Text style={styles.metaText}>{item.chapter}</Text> : null}
            <Text style={styles.metaText}>Page {item.page}</Text>
            {item.time ? <Text style={styles.metaText}>{item.time}</Text> : null}
          </View>
        </View>
      )}
      contentContainerStyle={styles.listContent}
    />
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: '#0f0f0f' },
  listContent: { padding: 20, paddingBottom: 40 },
  center: {
    flex: 1,
    backgroundColor: '#0f0f0f',
    alignItems: 'center',
    justifyContent: 'center',
    padding: 32,
  },
  header: { marginBottom: 20 },
  bookTitle: { fontSize: 20, fontWeight: '700', color: '#fff', marginBottom: 4 },
  count: { fontSize: 14, color: '#888' },
  card: {
    backgroundColor: '#1c1c1e',
    borderRadius: 14,
    padding: 16,
    marginBottom: 12,
    borderLeftWidth: 3,
    borderLeftColor: '#2563eb',
  },
  highlightText: {
    fontSize: 15,
    color: '#e5e7eb',
    lineHeight: 22,
    fontStyle: 'italic',
    marginBottom: 10,
  },
  meta: { flexDirection: 'row', gap: 12, flexWrap: 'wrap' },
  metaText: { fontSize: 12, color: '#666' },
  emptyIcon: { fontSize: 48, marginBottom: 16 },
  emptyTitle: { fontSize: 22, fontWeight: '700', color: '#fff', marginBottom: 8 },
  emptyDesc: { fontSize: 14, color: '#888', textAlign: 'center', lineHeight: 20, marginBottom: 24 },
  button: {
    backgroundColor: '#2563eb',
    borderRadius: 12,
    paddingVertical: 14,
    paddingHorizontal: 32,
    alignItems: 'center',
  },
  buttonText: { color: '#fff', fontWeight: '600', fontSize: 16 },
  loadingText: { color: '#888', marginTop: 16, fontSize: 14 },
  errorIcon: { fontSize: 40, marginBottom: 12 },
  errorText: { color: '#f87171', fontSize: 14, textAlign: 'center', marginBottom: 24 },
});
