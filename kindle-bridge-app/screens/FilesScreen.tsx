// screens/FilesScreen.tsx
import React, { useState } from 'react';
import {
  View, Text, StyleSheet, TouchableOpacity,
  Alert, ActivityIndicator, ScrollView,
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
  const [uploadProgress, setUploadProgress] = useState('');
  const [history, setHistory] = useState<UploadRecord[]>([]);

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
      setUploadProgress(`Uploading ${filename}...`);

      const res = await pushFile(
        config!,
        filename,
        uri,
        (sent, total) => {
          const pct = total > 0 ? Math.floor((sent / total) * 100) : 0;
          setUploadProgress(`Uploading ${filename} — ${pct}%`);
        },
      );

      if (res.ok) {
        setHistory((h) => [{ name: filename, bytes: size, status: 'ok' }, ...h]);
        setUploadProgress('');
        Alert.alert('Done', `${filename} sent to Kindle documents.`);
      } else {
        setHistory((h) => [{ name: filename, bytes: size, status: 'error', error: res.error }, ...h]);
        Alert.alert('Upload failed', res.error ?? 'Unknown error');
      }
    } catch (e: any) {
      Alert.alert('Error', e.message);
    } finally {
      setUploading(false);
      setUploadProgress('');
    }
  }

  function formatBytes(b: number) {
    if (b < 1024) return `${b} B`;
    if (b < 1024 * 1024) return `${(b / 1024).toFixed(1)} KB`;
    return `${(b / (1024 * 1024)).toFixed(1)} MB`;
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
        {uploading
          ? <ActivityIndicator color="#fff" />
          : <Text style={styles.buttonText}>Choose File to Send</Text>
        }
      </TouchableOpacity>

      {uploadProgress ? (
        <Text style={styles.progressText}>{uploadProgress}</Text>
      ) : null}

      <View style={styles.hint}>
        <Text style={styles.hintText}>
          Supported formats: EPUB, MOBI, PDF, AZW3, TXT{'\n'}
          Files are saved to /mnt/us/documents/ on the Kindle.
        </Text>
      </View>

      {history.length > 0 && (
        <>
          <Text style={styles.sectionLabel}>Recent Uploads</Text>
          {history.map((rec, i) => (
            <View key={i} style={[styles.historyRow, rec.status === 'error' && styles.historyError]}>
              <Text style={styles.historyIcon}>{rec.status === 'ok' ? '✓' : '✗'}</Text>
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
    marginBottom: 12,
  },
  buttonDisabled: { opacity: 0.6 },
  buttonText: { color: '#fff', fontWeight: '600', fontSize: 16 },
  progressText: { color: '#60a5fa', fontSize: 14, textAlign: 'center', marginBottom: 12 },
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
  historyInfo: { flex: 1 },
  historyName: { color: '#fff', fontSize: 15, fontWeight: '500' },
  historyMeta: { color: '#888', fontSize: 12, marginTop: 2 },
});
