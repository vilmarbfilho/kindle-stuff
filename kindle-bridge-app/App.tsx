// App.tsx
import React from 'react';
import { NavigationContainer } from '@react-navigation/native';
import { createBottomTabNavigator } from '@react-navigation/bottom-tabs';
import { StatusBar } from 'expo-status-bar';
import { Text, View, ActivityIndicator } from 'react-native';
import { SafeAreaProvider, useSafeAreaInsets } from 'react-native-safe-area-context';

import { KindleProvider, useKindle } from './context/KindleContext';
import DiscoveryScreen from './screens/DiscoveryScreen';
import DashboardScreen from './screens/DashboardScreen';
import RemoteScreen from './screens/RemoteScreen';
import SendTextScreen from './screens/SendTextScreen';
import FilesScreen from './screens/FilesScreen';
import HighlightsScreen from './screens/HighlightsScreen';

const Tab = createBottomTabNavigator();

function icon(name: string, focused: boolean) {
  const icons: Record<string, [string, string]> = {
    Dashboard:   ['📖', '📖'],
    Remote:      ['🎮', '🎮'],
    'Send Text': ['💬', '💬'],
    Files:       ['📁', '📁'],
    Highlights:  ['🔖', '🔖'],
  };
  const [active, inactive] = icons[name] ?? ['●', '○'];
  return (
    <Text style={{ fontSize: focused ? 22 : 20, opacity: focused ? 1 : 0.5 }}>
      {focused ? active : inactive}
    </Text>
  );
}

function AppTabs() {
  const insets = useSafeAreaInsets();
  return (
    <Tab.Navigator
      screenOptions={({ route }) => ({
        tabBarIcon: ({ focused }) => icon(route.name, focused),
        tabBarStyle: {
          backgroundColor: '#1c1c1e',
          borderTopColor: '#2c2c2e',
          paddingBottom: insets.bottom,
          height: 52 + insets.bottom,
        },
        tabBarActiveTintColor: '#2563eb',
        tabBarInactiveTintColor: '#888',
        tabBarLabelStyle: { fontSize: 11, fontWeight: '600' },
        headerStyle: { backgroundColor: '#1c1c1e' },
        headerTintColor: '#fff',
        headerTitleStyle: { fontWeight: '700' },
      })}
    >
      <Tab.Screen name="Dashboard"  component={DashboardScreen} />
      <Tab.Screen name="Remote"     component={RemoteScreen} />
      <Tab.Screen name="Send Text"  component={SendTextScreen} />
      <Tab.Screen name="Files"      component={FilesScreen} />
      <Tab.Screen name="Highlights" component={HighlightsScreen} />
    </Tab.Navigator>
  );
}

function Root() {
  const { config, loading } = useKindle();

  if (loading) {
    return (
      <View style={{ flex: 1, backgroundColor: '#0f0f0f', alignItems: 'center', justifyContent: 'center' }}>
        <ActivityIndicator size="large" color="#2563eb" />
        <Text style={{ color: '#888', marginTop: 16, fontSize: 14 }}>Loading...</Text>
      </View>
    );
  }

  return (
    <NavigationContainer>
      <StatusBar style="light" />
      {config ? <AppTabs /> : <DiscoveryScreen />}
    </NavigationContainer>
  );
}

export default function App() {
  return (
    <SafeAreaProvider>
      <KindleProvider>
        <Root />
      </KindleProvider>
    </SafeAreaProvider>
  );
}