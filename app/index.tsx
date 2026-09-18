import { useCallback, useEffect, useRef, useState } from 'react';
import { Pressable, SafeAreaView, StyleSheet, Text, View } from 'react-native';
import { Href, useRouter } from 'expo-router';
import type { Session } from '@supabase/supabase-js';

import { supabase } from '@/lib/supabase';

const ROUTES: Record<'signIn' | 'profileCompletion' | 'appHome', Href> = {
  signIn: '/sign-in',
  profileCompletion: '/profile-creation',
  appHome: '/(tabs)',
};

type GateState =
  | { kind: 'initializing' }
  | { kind: 'checking-profile'; userId: string }
  | { kind: 'session-error' }
  | { kind: 'profile-error'; userId: string }
  | { kind: 'ready'; destination: Href };

type ProfileRow = { id: string };

export default function SessionGateScreen() {
  const router = useRouter();
  const [gateState, setGateState] = useState<GateState>({ kind: 'initializing' });
  const operationRef = useRef(0);
  const processedUserIdRef = useRef<string | null>(null);
  const committedDestinationRef = useRef<Href | null>(null);

  const resolveSession = useCallback(async (session: Session | null, force = false) => {
    const userId = session?.user?.id;

    if (!userId) {
      ++operationRef.current;
      processedUserIdRef.current = null;
      setGateState({ kind: 'ready', destination: ROUTES.signIn });
      return;
    }

    if (!force && processedUserIdRef.current === userId) {
      return;
    }

    const operation = ++operationRef.current;
    processedUserIdRef.current = userId;
    setGateState({ kind: 'checking-profile', userId });

    const { data, error } = await supabase
      .from('profiles')
      .select('id')
      .eq('id', userId)
      .maybeSingle<ProfileRow>();

    if (operation !== operationRef.current) {
      return;
    }

    if (error) {
      processedUserIdRef.current = null;
      setGateState({ kind: 'profile-error', userId });
      return;
    }

    setGateState({
      kind: 'ready',
      destination: data === null ? ROUTES.profileCompletion : ROUTES.appHome,
    });
  }, []);

  useEffect(() => {
    let mounted = true;

    const { data: authListener } = supabase.auth.onAuthStateChange((_event, session) => {
      if (mounted) {
        void resolveSession(session);
      }
    });

    void (async () => {
      const initialOperation = operationRef.current;
      const { data, error } = await supabase.auth.getSession();

      if (!mounted || initialOperation !== operationRef.current) {
        return;
      }

      if (error) {
        setGateState({ kind: 'session-error' });
        return;
      }

      await resolveSession(data.session);
    })();

    return () => {
      mounted = false;
      authListener.subscription.unsubscribe();
    };
  }, [resolveSession]);

  useEffect(() => {
    if (gateState.kind !== 'ready') {
      return;
    }

    if (committedDestinationRef.current === gateState.destination) {
      return;
    }

    committedDestinationRef.current = gateState.destination;
    router.replace(gateState.destination);
  }, [gateState, router]);

  const retry = useCallback(async () => {
    setGateState({ kind: 'initializing' });
    const { data, error } = await supabase.auth.getSession();

    if (error) {
      setGateState({ kind: 'session-error' });
      return;
    }

    await resolveSession(data.session, true);
  }, [resolveSession]);

  if (gateState.kind === 'session-error' || gateState.kind === 'profile-error') {
    return (
      <SafeAreaView style={styles.page}>
        <View style={styles.content}>
          <Text style={styles.eyebrow}>DASHING</Text>
          <Text style={styles.title}>One more moment.</Text>
          <Text style={styles.body}>
            We could not check your profile yet. Your sign-in is still safe—please try again.
          </Text>
          <Pressable accessibilityRole="button" onPress={() => void retry()} style={styles.button}>
            <Text style={styles.buttonLabel}>Try again</Text>
          </Pressable>
        </View>
      </SafeAreaView>
    );
  }

  return (
    <SafeAreaView style={styles.page}>
      <View style={styles.content}>
        <Text style={styles.eyebrow}>DASHING</Text>
        <Text style={styles.title}>Style is loading.</Text>
        <Text style={styles.body}>Getting your space ready.</Text>
      </View>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  page: {
    flex: 1,
    backgroundColor: '#F8F5EF',
  },
  content: {
    flex: 1,
    justifyContent: 'center',
    paddingHorizontal: 28,
  },
  eyebrow: {
    color: '#FF6B7D',
    fontFamily: 'Inter_700Bold',
    fontSize: 12,
    letterSpacing: 2.2,
    marginBottom: 12,
  },
  title: {
    color: '#111111',
    fontFamily: 'PlayfairDisplay_700Bold',
    fontSize: 42,
    lineHeight: 48,
  },
  body: {
    color: '#111111',
    fontFamily: 'Inter_400Regular',
    fontSize: 16,
    lineHeight: 24,
    marginTop: 12,
    maxWidth: 300,
  },
  button: {
    alignSelf: 'flex-start',
    backgroundColor: '#FF6B7D',
    borderRadius: 999,
    marginTop: 28,
    paddingHorizontal: 22,
    paddingVertical: 14,
  },
  buttonLabel: {
    color: '#111111',
    fontFamily: 'Inter_700Bold',
    fontSize: 15,
  },
});
