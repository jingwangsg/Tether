import 'package:flutter/widgets.dart';

double estimatedMobileKeyBarHeightForMediaQuery(MediaQueryData media) {
  final shortestSide = media.size.shortestSide;
  final isTablet = shortestSide >= 600;
  final compact = media.size.width < 380;
  final buttonHeight = isTablet ? 42.0 : (compact ? 34.0 : 38.0);
  final rowGap = compact ? 6.0 : 8.0;
  const verticalPadding = 8.0 * 2;
  return buttonHeight * 2 + rowGap + verticalPadding + 4;
}

double effectiveTerminalSystemBottomInset(MediaQueryData media) {
  return media.viewInsets.bottom > 0 ? media.viewInsets.bottom : media.padding.bottom;
}

double terminalBottomObstructionForMediaQuery(
  MediaQueryData media, {
  required bool showKeyBar,
}) {
  final obstruction = effectiveTerminalSystemBottomInset(media);
  if (!showKeyBar) return obstruction;
  return obstruction + estimatedMobileKeyBarHeightForMediaQuery(media);
}

double mobileKeyBarBottomPaddingForMediaQuery(MediaQueryData media) {
  return media.viewInsets.bottom > 0 ? 0 : media.padding.bottom;
}
