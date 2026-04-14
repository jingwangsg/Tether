import 'package:flutter_test/flutter_test.dart';
import 'package:tether/widgets/terminal/terminal_controller.dart';

void main() {
  group('TerminalController', () {
    test('performAction calls attached callback', () {
      final controller = TerminalController();
      String? receivedAction;
      controller.attach(
        sendText: (_) {},
        paste: (_) {},
        showSearch: () {},
        performAction: (action) => receivedAction = action,
      );
      controller.performAction('increase_font_size:1');
      expect(receivedAction, 'increase_font_size:1');
    });

    test('performAction is no-op when detached', () {
      final controller = TerminalController();
      controller.attach(
        sendText: (_) {},
        paste: (_) {},
        showSearch: () {},
        performAction: (action) {},
      );
      controller.detach();
      // Should not throw
      controller.performAction('increase_font_size:1');
    });

    test('performAction is no-op when never attached', () {
      final controller = TerminalController();
      // Should not throw
      controller.performAction('increase_font_size:1');
    });
  });
}
