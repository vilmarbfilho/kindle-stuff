// screens/DiscoveryScreen.tsx
import React, { useState } from 'react';
import {
  View, Text, StyleSheet, TouchableOpacity,
  ActivityIndicator, TextInput, Alert,
} from 'react-native';
import { useKindle } from '../context/KindleContext';
import { discoverKindle, KindleConfig } from '../kindle';

export default function DiscoveryScreen() {
  const { setConfig } = useKindle();
  const [scanning, setScanning] = useState(false);
  const [progress, setProgress] = useState('');
  const [manualIp, setManualIp] = useState('');
  const [manualToken, setManualToken] = useState('');

  async function handleScan() {
    setScanning(true);
    setProgress('Detecting local network...');
    try {
      // derive subnet from a known reachable address via a WebRTC-free trick:
      // just try the most common home subnets
      const subnets = ['192.168.0', '192.168.1', '10.0.0', '10.0.1'];
      let found: KindleConfig | null = null;

      for (const subnet of subnets) {
        setProgress(`Scanning ${subnet}.1–254...`);
        found = await discoverKindle(subnet, (scanned, total) => {
          setProgress(`Scanning ${subnet} — ${scanned}/${total}`);
        });
        if (found) break;
      }

      if (found) {
        setProgress(`Found at ${found.ip}!`);
        setTimeout(() => setConfig(found), 600);
      } else {
        Alert.alert(
          'Not found',
          'No Kindle Bridge found on the local network.\n\nMake sure KOReader is open and the Kindle is on the same Wi-Fi.',
        );
        setProgress('');
      }
    } catch (e: any) {
      Alert.alert('Error', e.message);
      setProgress('');
    } finally {
      setScanning(false);
    }
  }

  async function handleManual() {
    if (!manualIp.trim() || !manualToken.trim()) {
      Alert.alert('Missing fields', 'Enter both IP address and token.');
      return;
    }
    setConfig({ ip: manualIp.trim(), port: 8080, token: manualToken.trim() });
  }

  return (
    <View style={styles.container}>
      <Text style={styles.title}>Kindle Bridge</Text>
      <Text style={styles.subtitle}>Connect to your Kindle</Text>

      {/* Auto discovery */}
      <View style={styles.card}>
        <Text style={styles.cardTitle}>Auto Discovery</Text>
        <Text style={styles.cardDesc}>
          Scans your Wi-Fi network to find the Kindle automatically.
          Make sure KOReader is open on the Kindle.
        </Text>
        <TouchableOpacity
          style={[styles.button, scanning && styles.buttonDisabled]}
          onPress={handleScan}
          disabled={scanning}
        >
          {scanning
            ? <ActivityIndicator color="#fff" />
            : <Text style={styles.buttonText}>Scan Network</Text>
          }
        </TouchableOpacity>
        {progress ? <Text style={styles.progressText}>{progress}</Text> : null}
      </View>

      {/* Manual entry */}
      <View style={styles.card}>
        <Text style={styles.cardTitle}>Manual Entry</Text>
        <TextInput
          style={styles.input}
          placeholder="Kindle IP (e.g. 192.168.0.106)"
          placeholderTextColor="#888"
          value={manualIp}
          onChangeText={setManualIp}
          keyboardType="decimal-pad"
          autoCapitalize="none"
        />
        <TextInput
          style={styles.input}
          placeholder="Auth Token (e.g. 20d3ec98)"
          placeholderTextColor="#888"
          value={manualToken}
          onChangeText={setManualToken}
          autoCapitalize="none"
          autoCorrect={false}
        />
        <TouchableOpacity style={styles.buttonOutline} onPress={handleManual}>
          <Text style={styles.buttonOutlineText}>Connect</Text>
        </TouchableOpacity>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#0f0f0f',
    alignItems: 'center',
    justifyContent: 'center',
    padding: 24,
  },
  title: {
    fontSize: 32,
    fontWeight: '700',
    color: '#fff',
    marginBottom: 4,
  },
  subtitle: {
    fontSize: 16,
    color: '#888',
    marginBottom: 32,
  },
  card: {
    width: '100%',
    backgroundColor: '#1c1c1e',
    borderRadius: 16,
    padding: 20,
    marginBottom: 16,
  },
  cardTitle: {
    fontSize: 17,
    fontWeight: '600',
    color: '#fff',
    marginBottom: 8,
  },
  cardDesc: {
    fontSize: 14,
    color: '#888',
    marginBottom: 16,
    lineHeight: 20,
  },
  button: {
    backgroundColor: '#2563eb',
    borderRadius: 12,
    paddingVertical: 14,
    alignItems: 'center',
  },
  buttonDisabled: {
    opacity: 0.6,
  },
  buttonText: {
    color: '#fff',
    fontWeight: '600',
    fontSize: 16,
  },
  buttonOutline: {
    borderWidth: 1,
    borderColor: '#2563eb',
    borderRadius: 12,
    paddingVertical: 14,
    alignItems: 'center',
    marginTop: 4,
  },
  buttonOutlineText: {
    color: '#2563eb',
    fontWeight: '600',
    fontSize: 16,
  },
  input: {
    backgroundColor: '#2c2c2e',
    borderRadius: 10,
    paddingHorizontal: 14,
    paddingVertical: 12,
    color: '#fff',
    fontSize: 15,
    marginBottom: 10,
  },
  progressText: {
    marginTop: 12,
    textAlign: 'center',
    color: '#60a5fa',
    fontSize: 14,
  },
});
