import { useState } from 'react';
import { Alert, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { updateMyVisibilityDefault } from '../data/dashing-data';
import { colors, spacing } from '../theme';

const OPTIONS: Array<{ label: string; hint: string; value: number | null }> = [
  { label: 'Everyone', hint: 'Any adult on Dashing', value: null },
  { label: 'Under 30', hint: 'Adults aged 18 to 29', value: 30 },
  { label: 'Under 25', hint: 'Adults aged 18 to 24', value: 25 },
  { label: 'Under 21', hint: 'Adults aged 18 to 20', value: 21 },
];

export function VisibilitySetting({ initial }: { initial: number | null }) {
  const [value, setValue] = useState<number | null>(initial);
  const [busy, setBusy] = useState(false);

  const choose = async (next: number | null) => {
    const previous = value;
    setValue(next);
    setBusy(true);
    try {
      await updateMyVisibilityDefault(next);
    } catch (error) {
      setValue(previous);
      Alert.alert(
        'Could not save that',
        error instanceof Error ? error.message : 'Please try again.',
      );
    } finally {
      setBusy(false);
    }
  };

  return (
    <ScrollView contentContainerStyle={styles.scroll}>
      <Text style={styles.label}>WHO CAN SEE YOUR POSTS</Text>
      <Text style={styles.muted}>
        Sets the oldest viewer allowed on your new posts. You can override it per post.
      </Text>

      <View style={styles.group}>
        {OPTIONS.map((option) => {
          const selected = option.value === value;
          return (
            <Pressable
              key={option.label}
              accessibilityRole="radio"
              accessibilityState={{ selected }}
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
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  scroll: { gap: spacing.md, padding: spacing.lg },
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
