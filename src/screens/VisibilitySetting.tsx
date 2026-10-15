import { useEffect, useState } from 'react';
import { Alert, Pressable, StyleSheet, Text, View } from 'react-native';
import { updateMyVisibilityDefault, viewerAgeOptionsFor } from '../data/dashing-data';
import { colors, spacing } from '../theme';

/**
 * Default "who can see my posts" setting. Only offers ceilings at or above
 * the user's own age; the database enforces the same rule.
 */
export function VisibilitySetting({ initial, ownAge }: { initial: number | null; ownAge: number }) {
  const [value, setValue] = useState<number | null>(initial);
  const [busy, setBusy] = useState(false);

  // `initial` can arrive after first render (loaded from the server).
  useEffect(() => {
    setValue(initial);
  }, [initial]);

  const options = viewerAgeOptionsFor(ownAge);

  const choose = async (next: number | null) => {
    const previous = value;
    setValue(next);
    setBusy(true);
    try {
      await updateMyVisibilityDefault(next);
    } catch (error) {
      setValue(previous);
      Alert.alert('Could not save that', error instanceof Error ? error.message : 'Please try again.');
    } finally {
      setBusy(false);
    }
  };

  return (
    <View style={styles.wrap}>
      <Text style={styles.label}>WHO CAN SEE YOUR POSTS</Text>
      <Text style={styles.muted}>
        Hide your new posts from people older than a limit you choose. You can change it for each post.
      </Text>

      <View style={styles.group} accessibilityRole="radiogroup">
        {options.map((option) => {
          const selected = option.value === value;
          return (
            <Pressable
              key={option.label}
              accessibilityRole="radio"
              accessibilityState={{ selected, disabled: busy }}
              accessibilityLabel={`${option.label}. ${option.hint}`}
              disabled={busy}
              onPress={() => void choose(option.value)}
              style={[styles.row, selected && styles.rowSelected]}
            >
              <View>
                <Text style={styles.rowLabel}>{option.label}</Text>
                <Text style={styles.rowHint}>{option.hint}</Text>
              </View>
              {selected && <Text style={styles.tick}>✓</Text>}
            </Pressable>
          );
        })}
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  wrap: { gap: spacing.md },
  label: { color: colors.dashing, fontSize: 11, fontWeight: '700', letterSpacing: 2 },
  muted: { color: colors.inkMuted, fontSize: 14, lineHeight: 20 },
  group: { borderColor: colors.line, borderRadius: 16, borderWidth: 1, overflow: 'hidden' },
  row: {
    alignItems: 'center',
    borderBottomColor: colors.line,
    borderBottomWidth: StyleSheet.hairlineWidth,
    flexDirection: 'row',
    justifyContent: 'space-between',
    minHeight: 60,
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.sm,
  },
  rowSelected: { backgroundColor: colors.panel },
  rowLabel: { color: colors.ivory, fontSize: 16 },
  rowHint: { color: colors.inkMuted, fontSize: 12, marginTop: 2 },
  tick: { color: colors.dashing, fontSize: 16 },
});
