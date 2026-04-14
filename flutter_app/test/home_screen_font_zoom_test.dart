import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tether/screens/home_screen.dart';

void main() {
  group('HomeScreen.fontZoomAction', () {
    test('Cmd+= maps to increase_font_size:1', () {
      expect(
        HomeScreen.fontZoomAction(LogicalKeyboardKey.equal),
        'increase_font_size:1',
      );
    });

    test('Cmd+Shift+= (add/plus) maps to increase_font_size:1', () {
      expect(
        HomeScreen.fontZoomAction(LogicalKeyboardKey.add),
        'increase_font_size:1',
      );
    });

    test('numpad + maps to increase_font_size:1', () {
      expect(
        HomeScreen.fontZoomAction(LogicalKeyboardKey.numpadAdd),
        'increase_font_size:1',
      );
    });

    test('Cmd+- maps to decrease_font_size:1', () {
      expect(
        HomeScreen.fontZoomAction(LogicalKeyboardKey.minus),
        'decrease_font_size:1',
      );
    });

    test('numpad - maps to decrease_font_size:1', () {
      expect(
        HomeScreen.fontZoomAction(LogicalKeyboardKey.numpadSubtract),
        'decrease_font_size:1',
      );
    });

    test('Cmd+0 maps to reset_font_size', () {
      expect(
        HomeScreen.fontZoomAction(LogicalKeyboardKey.digit0),
        'reset_font_size',
      );
    });

    test('numpad 0 maps to reset_font_size', () {
      expect(
        HomeScreen.fontZoomAction(LogicalKeyboardKey.numpad0),
        'reset_font_size',
      );
    });

    test('non-zoom key returns null', () {
      expect(HomeScreen.fontZoomAction(LogicalKeyboardKey.keyA), isNull);
      expect(HomeScreen.fontZoomAction(LogicalKeyboardKey.keyZ), isNull);
    });
  });
}
