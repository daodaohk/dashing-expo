import { PropsWithChildren } from 'react';
import { Pressable, StyleSheet, Text, TextInput, View } from 'react-native';
import { colors, spacing, type } from './theme';

export function Mark({ light = false }: { light?: boolean }) {
  return <Text style={[styles.mark, { color: light ? colors.ivory : colors.dashing }]}>✦</Text>;
}

export function Brand() {
  return <View style={styles.brand}><Mark /><Text style={styles.brandText}>Dashing</Text></View>;
}

export function Eyebrow({ children }: PropsWithChildren) {
  return <Text style={styles.eyebrow}>{children}</Text>;
}

export function Button({ label, onPress, secondary = false, disabled = false }: { label: string; onPress: () => void; secondary?: boolean; disabled?: boolean }) {
  return <Pressable disabled={disabled} onPress={onPress} style={[styles.button, secondary && styles.buttonSecondary, disabled && styles.buttonDisabled]}>
    <Text style={[styles.buttonLabel, secondary && styles.buttonLabelSecondary]}>{label}</Text>
  </Pressable>;
}

export function Field({ value, onChangeText, placeholder, multiline = false, secureTextEntry = false }: { value: string; onChangeText: (value: string) => void; placeholder: string; multiline?: boolean; secureTextEntry?: boolean }) {
  return <TextInput value={value} onChangeText={onChangeText} placeholder={placeholder} placeholderTextColor={colors.inkMuted} multiline={multiline} secureTextEntry={secureTextEntry} autoCapitalize="none" style={[styles.field, multiline && styles.fieldMulti]} />;
}

const styles = StyleSheet.create({
  mark: { fontSize: 32, lineHeight: 34 },
  brand: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  brandText: { color: colors.ivory, fontFamily: type.display, fontSize: 28, letterSpacing: -1 },
  eyebrow: { color: colors.dashing, fontSize: 11, fontWeight: '700', letterSpacing: 2, textTransform: 'uppercase' },
  button: { backgroundColor: colors.dashing, minHeight: 52, borderRadius: 16, alignItems: 'center', justifyContent: 'center', paddingHorizontal: spacing.lg },
  buttonSecondary: { backgroundColor: 'transparent', borderColor: colors.line, borderWidth: 1 },
  buttonDisabled: { opacity: 0.45 },
  buttonLabel: { color: colors.charcoal, fontWeight: '800', fontSize: 15 },
  buttonLabelSecondary: { color: colors.ivory },
  field: { backgroundColor: colors.panel, borderWidth: 1, borderColor: colors.line, color: colors.ivory, borderRadius: 14, minHeight: 50, paddingHorizontal: spacing.md, fontSize: 16 },
  fieldMulti: { minHeight: 100, paddingTop: spacing.sm, textAlignVertical: 'top' },
});
