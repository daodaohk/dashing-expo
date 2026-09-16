import type { Session } from '@supabase/supabase-js';

import { supabase } from '../config/supabase.js';
import type { ProfileRow } from '../types/database.js';

export interface OnboardingProfile {
  username: string;
  displayName: string;
  dateOfBirth: string;
}

export async function sendSignInLink(email: string) {
  const redirectTo = process.env.EXPO_PUBLIC_AUTH_REDIRECT_URL;
  const { error } = await supabase.auth.signInWithOtp({
    email: email.trim().toLowerCase(),
    options: redirectTo ? { emailRedirectTo: redirectTo } : undefined,
  });

  if (error) throw error;
}

export async function getSession(): Promise<Session | null> {
  const { data, error } = await supabase.auth.getSession();
  if (error) throw error;
  return data.session;
}

export async function getMyProfile(): Promise<ProfileRow | null> {
  const session = await getSession();
  if (!session) return null;

  const { data, error } = await supabase
    .from('profiles')
    .select('*')
    .eq('id', session.user.id)
    .maybeSingle();
  if (error) throw error;
  return data;
}

/**
 * The database trigger/RLS policy is the authority for the 18+ decision.
 * This sends the DOB to the existing profile flow but never trusts a client
 * age calculation to unlock adult content.
 */
export async function completeOnboarding(input: OnboardingProfile): Promise<ProfileRow> {
  const session = await getSession();
  if (!session) throw new Error('Sign in before completing onboarding.');

  const { data, error } = await supabase
    .from('profiles')
    .upsert(
      {
        id: session.user.id,
        username: input.username.trim().toLowerCase(),
        display_name: input.displayName.trim(),
        // Existing migration validates/stores date_of_birth and derives eligibility.
        date_of_birth: input.dateOfBirth,
      } as never,
      { onConflict: 'id' },
    )
    .select('*')
    .single();
  if (error) throw error;
  return data;
}

export async function signOut() {
  const { error } = await supabase.auth.signOut();
  if (error) throw error;
}
