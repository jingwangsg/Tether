class MobileKey {
  final String label;
  final String value;
  final bool isModifier;

  const MobileKey({
    required this.label,
    required this.value,
    this.isModifier = false,
  });

  Map<String, dynamic> toJson() => {
        'label': label,
        'value': value,
        'isModifier': isModifier,
      };

  factory MobileKey.fromJson(Map<String, dynamic> json) {
    return MobileKey(
      label: json['label'] as String,
      value: json['value'] as String,
      isModifier: json['isModifier'] as bool? ?? false,
    );
  }
}

const defaultMobileKeys = [
  MobileKey(label: 'Esc', value: '\x1b'),
  MobileKey(label: 'S-Tab', value: '\x1b[Z'),
  MobileKey(label: 'Tab', value: '\t'),
  MobileKey(label: 'Ctrl', value: 'ctrl', isModifier: true),
  MobileKey(label: 'Alt', value: 'alt', isModifier: true),
  MobileKey(label: '←', value: '\x1b[D'),
  MobileKey(label: '→', value: '\x1b[C'),
  MobileKey(label: '↑', value: '\x1b[A'),
  MobileKey(label: '↓', value: '\x1b[B'),
];

const defaultCustomKeys = [
  MobileKey(label: 'C-c', value: '\x03'),
  MobileKey(label: 'C-d', value: '\x04'),
];

String parseKeyCombo(String input) {
  final normalized = input.trim();

  final ctrlMatch = RegExp(r'^[Cc](?:trl)?\+?(.)$').firstMatch(normalized);
  if (ctrlMatch != null) {
    final char = ctrlMatch.group(1)!.toUpperCase();
    final code = char.codeUnitAt(0);
    if (code >= 65 && code <= 90) {
      return String.fromCharCode(code - 64);
    }
  }

  final altMatch = RegExp(r'^[Aa](?:lt)?\+?(.)$').firstMatch(normalized);
  if (altMatch != null) {
    return '\x1b${altMatch.group(1)}';
  }

  return normalized;
}
