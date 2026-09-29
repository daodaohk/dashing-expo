import { useEffect, useState } from 'react';
import { Image, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { Button, Brand } from '../components';
import { loadMyVisibilityDefault } from '../data/dashing-data';
import { colors, spacing, type } from '../theme';
import { Post } from '../types';
import type { ProfileRow } from '../types/database';
import { VisibilitySetting } from './VisibilitySetting';

export function Profile({ posts, onOpen, profile, onSignOut }: {
  posts: Post[];
  onOpen: (post: Post) => void;
  profile: ProfileRow;
  onSignOut: () => void;
}) {
  const name = profile.display_name || profile.username;
  const [visibilityDefault, setVisibilityDefault] = useState<number | null>(
    profile.default_max_viewer_age ?? null,
  );

  useEffect(() => {
    let active = true;
    void loadMyVisibilityDefault()
      .then((value) => {
        if (active) setVisibilityDefault(value);
      })
      .catch(() => {
        /* keep the value we already have */
      });
    return () => {
      active = false;
    };
  }, []);

  return (
    <ScrollView contentContainerStyle={styles.scroll}>
      <View style={styles.topbar}>
        <Brand />
        <Text style={styles.step}>EDIT</Text>
      </View>

      <View style={styles.profileHead}>
        <View style={styles.avatar}>
          <Text style={styles.avatarText}>{name.slice(0, 1).toUpperCase()}</Text>
        </View>
        <View>
          <Text style={styles.detailTitle}>{name}’s style</Text>
          <Text style={styles.location}>Member · verified adult</Text>
        </View>
      </View>

      <Text style={styles.copy}>Thoughtful layers, bold details, always moving.</Text>

      <View style={styles.statRow}>
        <Stat value="4.7" label="STYLE AVG" />
        <Stat value="12" label="LOOKS" />
        <Stat value="3" label="TAGS" />
      </View>

      <Text style={styles.sectionTitle}>Your looks</Text>
      <View style={styles.grid}>
        {posts.slice(0, 4).map((post) => (
          <Pressable key={post.id} onPress={() => onOpen(post)} style={styles.gridItem}>
            <Image source={{ uri: post.imageUrls[0] }} style={styles.gridImage} />
          </Pressable>
        ))}
      </View>

      <View style={styles.notice}>
        <Text style={styles.noticeTitle}>Safety stays server-side</Text>
        <Text style={styles.muted}>
          Profile eligibility, post visibility, and age ceilings are enforced through Supabase
          policies and RPCs—not this interface.
        </Text>
      </View>

      <Text style={styles.sectionTitle}>Privacy</Text>
      <VisibilitySetting initial={visibilityDefault} />

      <Button label="Sign out" secondary onPress={onSignOut} />
    </ScrollView>
  );
}

function Stat({ value, label }: { value: string; label: string }) {
  return (
    <View style={statStyles.wrap}>
      <Text style={statStyles.value}>{value}</Text>
      <Text style={statStyles.label}>{label}</Text>
    </View>
  );
}

const statStyles = StyleSheet.create({
  wrap: { flex: 1, gap: 2 },
  value: { color: colors.ivory, fontFamily: type.display, fontSize: 22 },
  label: { color: colors.inkMuted, fontSize: 10, fontWeight: '700', letterSpacing: 1.5 },
});

const styles = StyleSheet.create({
  scroll: { padding: spacing.lg, gap: spacing.md },
  topbar: { alignItems: 'center', flexDirection: 'row', justifyContent: 'space-between' },
  step: { color: colors.inkMuted, fontSize: 11, fontWeight: '700', letterSpacing: 2 },
  profileHead: {
    alignItems: 'center',
    flexDirection: 'row',
    gap: spacing.md,
    marginTop: spacing.sm,
  },
  avatar: {
    alignItems: 'center',
    backgroundColor: colors.panel,
    borderColor: colors.line,
    borderRadius: 999,
    borderWidth: 1,
    height: 64,
    justifyContent: 'center',
    width: 64,
  },
  avatarText: { color: colors.dashing, fontFamily: type.display, fontSize: 28 },
  detailTitle: { color: colors.ivory, fontFamily: type.display, fontSize: 22 },
  location: { color: colors.inkMuted, fontSize: 13, marginTop: 2 },
  copy: { color: colors.ivory, fontSize: 15, lineHeight: 22 },
  statRow: { flexDirection: 'row', gap: spacing.md, marginVertical: spacing.sm },
  sectionTitle: { color: colors.ivory, fontFamily: type.display, fontSize: 20, marginTop: spacing.sm },
  grid: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.sm },
  gridItem: { aspectRatio: 1, borderRadius: 14, overflow: 'hidden', width: '48%' },
  gridImage: { height: '100%', width: '100%' },
  notice: { borderColor: colors.line, borderRadius: 14, borderWidth: 1, gap: 4, padding: spacing.md },
  noticeTitle: { color: colors.ivory, fontSize: 14, fontWeight: '700' },
  muted: { color: colors.inkMuted, fontSize: 14, lineHeight: 20 },
});
