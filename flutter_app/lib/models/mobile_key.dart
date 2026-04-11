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

const mobileEscKey = MobileKey(label: 'Esc', value: '\x1b');
const mobileShiftTabKey = MobileKey(label: 'S-Tab', value: '\x1b[Z');
const mobileTabKey = MobileKey(label: 'Tab', value: '\t');
const mobileCtrlKey = MobileKey(label: 'Ctrl', value: 'ctrl', isModifier: true);
const mobileAltKey = MobileKey(label: 'Alt', value: 'alt', isModifier: true);
const mobileTildeKey = MobileKey(label: '~', value: '~');
const mobileSlashKey = MobileKey(label: '/', value: '/');

const mobileArrowLeftKey = MobileKey(label: '←', value: '\x1b[D');
const mobileArrowRightKey = MobileKey(label: '→', value: '\x1b[C');
const mobileArrowUpKey = MobileKey(label: '↑', value: '\x1b[A');
const mobileArrowDownKey = MobileKey(label: '↓', value: '\x1b[B');
const mobileHomeKey = MobileKey(label: 'Home', value: '\x1b[H');
const mobileEndKey = MobileKey(label: 'End', value: '\x1b[F');
const mobilePageUpKey = MobileKey(label: 'PgUp', value: '\x1b[5~');
const mobilePageDownKey = MobileKey(label: 'PgDn', value: '\x1b[6~');

const defaultMobileToolbarKeys = [
  mobileEscKey,
  mobileShiftTabKey,
  mobileTabKey,
  mobileCtrlKey,
  mobileAltKey,
  mobileTildeKey,
  mobileSlashKey,
];

const defaultMobileNavigationKeys = [
  mobileArrowUpKey,
  mobileArrowLeftKey,
  mobileArrowDownKey,
  mobileArrowRightKey,
];

const defaultMobileNavigationRows = <List<MobileKey?>>[
  [null, mobileArrowUpKey, null],
  [mobileArrowLeftKey, mobileArrowDownKey, mobileArrowRightKey],
];

const defaultMobileKeys = defaultMobileToolbarKeys;

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
