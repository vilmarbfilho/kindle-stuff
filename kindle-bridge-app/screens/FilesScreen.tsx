// screens/FilesScreen.tsx
import React, { useState } from 'react';
import {
  View, Text, StyleSheet, TouchableOpacity,
  Alert, ScrollView, Animated,
} from 'react-native';
import * as DocumentPicker from 'expo-document-picker';
import { useKindle } from '../context/KindleContext';
import { pushFile } from '../kindle';

interface UploadRecord {
  name: string;
  bytes: number;
  status: 'ok' | 'error';
  error?: string;
}

export default function FilesScreen() {
  const { config } = useKindle();
  const [uploading, setUploading] = useState(false);
  const [uploadFile, setUploadFile] = useState('');
  const [progress, setProgress] = useState(0);       // 0–100
  const [progressBytes, setProgressBytes] = useState({ sent: 0, total: 0 });
  const [history, setHistory] = useState<UploadRecord[]>([]);

  function formatBytes(b: number) {
    if (b < 1024) return `${b} B`;
    if (b < 1024 * 1024) return `${(b / 1024).toFixed(1)} KB`;
    return `${(b / (1024 * 1024)).toFixed(1)} MB`;
  }

  async function handlePick() {
    try {
      const result = await DocumentPicker.getDocumentAsync({
        type: ['application/epub+zip', 'application/pdf',
               'application/x-mobipocket-ebook', '*/*'],
        copyToCacheDirectory: true,
      });

      if (result.canceled || !result.assets?.length) return;

      const asset = result.assets[0];
      const filename = asset.name;
      const uri = asset.uri;
      const size = asset.size ?? 0;

      setUploading(true);
      setUploadFile(filename);
      setProgress(0);
      setProgressBytes({ sent: 0, total: size });

      const res = await pushFile(
        config!,
        filename,
        uri,
        (sent, total) => {
          const pct = total > 0 ? Math.floor((sent / total) * 100) : 0;
          setProgress(pct);
          setProgressBytes({ sent, total });
        },
      );

      if (res.ok) {
        setProgress(100);
        setHistory((h) => [{ name: filename, bytes: size, status: 'ok' }, ...h]);
        setTimeout(() => {
          setUploading(false);
          setUploadFile('');
          setProgress(0);
        }, 1000);
      } else {
        setHistory((h) => [{ name: filename, bytes: size, status: 'error', error: res.error }, ...h]);
        Alert.alert('Upload failed', res.error ?? 'Unknown error');
        setUploading(false);
        setUploadFile('');
        setProgress(0);
      }
    } catch (e: any) {
      Alert.alert('Error', e.message);
      setUploading(false);
      setUploadFile('');
      setProgress(0);
    }
  }

  return (
    <ScrollView style={styles.container} contentContainerStyle={styles.content}>
      <Text style={styles.title}>Push Files</Text>
      <Text style={styles.subtitle}>Send books and documents to your Kindle</Text>

      <TouchableOpacity
        style={[styles.button, uploading && styles.buttonDisabled]}
        onPress={handlePick}
        disabled={uploading}
      >
        <Text style={styles.buttonText}>
          {uploading ? 'Uploading...' : 'Choose File to Send'}
        </Text>
      </TouchableOpacity>

      {/* Upload progress */}
      {uploading && (
        <View style={styles.progressCard}>
          <Text style={styles.progressFilename} numberOfLines={1}>
            {uploadFile}
          </Text>

          {/* Progress bar */}
          <View style={styles.progressBarBg}>
            <View style={[styles.progressBarFill, { width: `${progress}%` }]} />
          </View>

          <View style={styles.progressRow}>
            <Text style={styles.progressPct}>{progress}%</Text>
            <Text style={styles.progressSize}>
              {formatBytes(progressBytes.sent)} / {formatBytes(progressBytes.total)}
            </Text>
          </View>
        </View>
      )}

      <View style={styles.hint}>
        <Text style={styles.hintText}>
          Supported formats: EPUB, MOBI, PDF, AZW3, TXT{'\n'}
          Files are saved to /mnt/us/documents/ on the Kindle.{'\n'}
          Accented filenames are automatically transliterated.
        </Text>
      </View>

      {history.length > 0 && (
        <>
          <Text style={styles.sectionLabel}>Recent Uploads</Text>
          {history.map((rec, i) => (
            <View key={i} style={[styles.historyRow, rec.status === 'error' && styles.historyError]}>
              <Text style={[styles.historyIcon, rec.status === 'error' && styles.historyIconError]}>
                {rec.status === 'ok' ? '✓' : '✗'}
              </Text>
              <View style={styles.historyInfo}>
                <Text style={styles.historyName} numberOfLines={1}>{rec.name}</Text>
                <Text style={styles.historyMeta}>
                  {formatBytes(rec.bytes)}{rec.error ? ` · ${rec.error}` : ''}
                </Text>
              </View>
            </View>
          ))}
        </>
      )}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: '#0f0f0f' },
  content: { padding: 24 },
  title: { fontSize: 26, fontWeight: '700', color: '#fff', marginBottom: 6 },
  subtitle: { fontSize: 14, color: '#888', marginBottom: 24 },
  button: {
    backgroundColor: '#2563eb',
    borderRadius: 12,
    paddingVertical: 16,
    alignItems: 'center',
    marginBottom: 16,
  },
  buttonDisabled: { opacity: 0.5 },
  buttonText: { color: '#fff', fontWeight: '600', fontSize: 16 },

  progressCard: {
    backgroundColor: '#1c1c1e',
    borderRadius: 14,
    padding: 16,
    marginBottom: 16,
  },
  progressFilename: {
    color: '#fff',
    fontSize: 14,
    fontWeight: '500',
    marginBottom: 12,
  },
  progressBarBg: {
    height: 8,
    backgroundColor: '#2c2c2e',
    borderRadius: 4,
    overflow: 'hidden',
    marginBottom: 8,
  },
  progressBarFill: {
    height: '100%',
    backgroundColor: '#2563eb',
    borderRadius: 4,
  },
  progressRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
  },
  progressPct: {
    color: '#60a5fa',
    fontSize: 13,
    fontWeight: '600',
  },
  progressSize: {
    color: '#888',
    fontSize: 13,
  },

  hint: {
    backgroundColor: '#1c1c1e',
    borderRadius: 12,
    padding: 16,
    marginBottom: 24,
  },
  hintText: { color: '#666', fontSize: 13, lineHeight: 20 },
  sectionLabel: {
    color: '#888',
    fontSize: 13,
    fontWeight: '600',
    textTransform: 'uppercase',
    letterSpacing: 1,
    marginBottom: 10,
  },
  historyRow: {
    backgroundColor: '#1c1c1e',
    borderRadius: 12,
    padding: 14,
    flexDirection: 'row',
    alignItems: 'center',
    marginBottom: 8,
  },
  historyError: { borderWidth: 1, borderColor: '#7f1d1d' },
  historyIcon: { fontSize: 18, marginRight: 12, color: '#22c55e' },
  historyIconError: { color: '#ef4444' },
  historyInfo: { flex: 1 },
  historyName: { color: '#fff', fontSize: 15, fontWeight: '500' },
  historyMeta: { color: '#888', fontSize: 12, marginTop: 2 },
});