// screens/SendTextScreen.tsx
import React, { useState } from 'react';
import {
  View, Text, StyleSheet, TextInput,
  TouchableOpacity, Alert, ActivityIndicator,
  KeyboardAvoidingView, Platform, ScrollView,
} from 'react-native';
import { useKindle } from '../context/KindleContext';
import { sendText } from '../kindle';

const QUICK_MESSAGES = [
  'Dinner is ready!',
  'Time to take a break.',
  'Phone call for you.',
  'Going to sleep, good night!',
];

export default function SendTextScreen() {
  const { config } = useKindle();
  const [text, setText] = useState('');
  const [sending, setSending] = useState(false);
  const [lastSent, setLastSent] = useState('');

  async function handleSend(message?: string) {
    const msg = (message ?? text).trim();
    if (!msg) { Alert.alert('Empty message', 'Type something to send.'); return; }
    if (!config) return;

    setSending(true);
    try {
      await sendText(config, msg);
      setLastSent(msg);
      if (!message) setText('');
    } catch (e: any) {
      Alert.alert('Error', e.message);
    } finally {
      setSending(false);
    }
  }

  return (
    <KeyboardAvoidingView
      style={styles.container}
      behavior={Platform.OS === 'ios' ? 'padding' : undefined}
    >
      <ScrollView contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled">
        <Text style={styles.title}>Send Text</Text>
        <Text style={styles.subtitle}>Display a message on the Kindle screen</Text>

        <TextInput
          style={styles.input}
          placeholder="Type your message..."
          placeholderTextColor="#555"
          value={text}
          onChangeText={setText}
          multiline
          numberOfLines={4}
          textAlignVertical="top"
        />

        <TouchableOpacity
          style={[styles.button, sending && styles.buttonDisabled]}
          onPress={() => handleSend()}
          disabled={sending}
        >
          {sending
            ? <ActivityIndicator color="#fff" />
            : <Text style={styles.buttonText}>Send to Kindle</Text>
          }
        </TouchableOpacity>

        {lastSent ? (
          <View style={styles.sentBadge}>
            <Text style={styles.sentText}>✓ Sent: "{lastSent}"</Text>
          </View>
        ) : null}

        {/* Quick messages */}
        <Text style={styles.sectionLabel}>Quick Messages</Text>
        {QUICK_MESSAGES.map((msg) => (
          <TouchableOpacity
            key={msg}
            style={styles.quickBtn}
            onPress={() => handleSend(msg)}
            disabled={sending}
          >
            <Text style={styles.quickBtnText}>{msg}</Text>
            <Text style={styles.quickBtnArrow}>→</Text>
          </TouchableOpacity>
        ))}
      </ScrollView>
    </KeyboardAvoidingView>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: '#0f0f0f' },
  content: { padding: 24 },
  title: {
    fontSize: 26,
    fontWeight: '700',
    color: '#fff',
    marginBottom: 6,
  },
  subtitle: {
    fontSize: 14,
    color: '#888',
    marginBottom: 24,
  },
  input: {
    backgroundColor: '#1c1c1e',
    borderRadius: 14,
    padding: 16,
    color: '#fff',
    fontSize: 16,
    minHeight: 120,
    marginBottom: 14,
  },
  button: {
    backgroundColor: '#2563eb',
    borderRadius: 12,
    paddingVertical: 14,
    alignItems: 'center',
    marginBottom: 16,
  },
  buttonDisabled: { opacity: 0.6 },
  buttonText: { color: '#fff', fontWeight: '600', fontSize: 16 },
  sentBadge: {
    backgroundColor: '#14532d',
    borderRadius: 10,
    padding: 12,
    marginBottom: 24,
  },
  sentText: { color: '#86efac', fontSize: 14 },
  sectionLabel: {
    color: '#888',
    fontSize: 13,
    fontWeight: '600',
    textTransform: 'uppercase',
    letterSpacing: 1,
    marginBottom: 10,
  },
  quickBtn: {
    backgroundColor: '#1c1c1e',
    borderRadius: 12,
    paddingHorizontal: 16,
    paddingVertical: 14,
    flexDirection: 'row',
    alignItems: 'center',
    marginBottom: 8,
  },
  quickBtnText: { flex: 1, color: '#fff', fontSize: 15 },
  quickBtnArrow: { color: '#2563eb', fontSize: 18 },
});
