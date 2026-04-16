import 'package:flutter_test/flutter_test.dart';
import 'package:tether/widgets/terminal/selection_handles_overlay.dart';

void main() {
  group('LongPressDragTracker', () {
    late LongPressDragTracker tracker;

    setUp(() {
      tracker = LongPressDragTracker();
    });

    test('initial state: no override', () {
      expect(
        tracker.onSelectionChanged(hasSelection: true),
        isFalse,
      );
    });

    test('pointer down then immediate selection (double tap) does not activate',
        () {
      tracker.onPointerDown(const Offset(100, 100));
      // Selection happens immediately (< 400ms) -> double tap, not long press
      expect(
        tracker.onSelectionChanged(hasSelection: true),
        isFalse,
      );
      expect(tracker.longPressDragActive, isFalse);
    });

    test('pointer up resets state', () {
      tracker.onPointerDown(const Offset(100, 100));
      tracker.longPressDragActive = true; // simulate activated
      tracker.onPointerUpOrCancel();
      expect(tracker.touchDown, isFalse);
      expect(tracker.longPressDragActive, isFalse);
    });

    test('handle dragging prevents override', () {
      tracker.onPointerDown(const Offset(100, 100));
      tracker.longPressDragActive = true;
      tracker.handleDragging = true;
      expect(
        tracker.onSelectionChanged(hasSelection: true),
        isFalse,
      );
    });

    test('second selection change during long press returns true', () {
      tracker.onPointerDown(const Offset(100, 100));
      // Simulate time passing (> 400ms)
      tracker.touchDownTime =
          DateTime.now().subtract(const Duration(milliseconds: 500));

      // First selection -> activates but does not override
      expect(
        tracker.onSelectionChanged(hasSelection: true),
        isFalse,
      );
      expect(tracker.longPressDragActive, isTrue);

      // Move finger
      tracker.onPointerMove(const Offset(200, 100));

      // Second selection (from xterm's onLongPressMoveUpdate) -> override
      expect(
        tracker.onSelectionChanged(hasSelection: true),
        isTrue,
      );
    });

    test('no selection clears override request', () {
      tracker.onPointerDown(const Offset(100, 100));
      tracker.longPressDragActive = true;
      expect(
        tracker.onSelectionChanged(hasSelection: false),
        isFalse,
      );
    });
  });
}
