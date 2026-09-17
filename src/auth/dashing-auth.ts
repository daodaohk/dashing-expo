import type { Session } from '@supabase/supabase-js';

import { supabase } from '../config/supabase';
import type { ProfileRow } from '../types/database';

export interface OnboardingProfile {
  username: string;
  displayName: string;
  dateOfBirth: string;
  country: string;
  city: string;
}

export async function signInWithPassword(email: string, password: string) {
  const { error } = await supabase.auth.signInWithPassword({
    email: email.trim().toLowerCase(),
    password,
  });
  if (error) throw error;
}

export async function createAccount(email: string, password: string) {
  const { data, error } = await supabase.auth.signUp({
    email: email.trim().toLowerCase(),
    password,
  });
  if (error) throw error;
  return data.session;
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

/** The database policy is the authority for the 18+ decision. */
export async function completeOnboarding(input: OnboardingProfile): Promise<ProfileRow> {
  const session = await getSession();
  if (!session) throw new Error('Sign in before completing your profile.');

  const { data, error } = await supabase
    .from('profiles')
    .upsert(
      {
        id: session.user.id,
        username: input.username.trim().toLowerCase(),
        display_name: input.displayName.trim(),
        date_of_birth: input.dateOfBirth,
        country: input.country.trim(),
        city: input.city.trim(),
      } as never,
      { onConflict: 'id' },
    )
    .select('*')
    .single();
  if (error) throw error;
  return data as ProfileRow;
}

export async function signOut() {
  const { error } = await supabase.auth.signOut();
  if (error) throw error;
}
