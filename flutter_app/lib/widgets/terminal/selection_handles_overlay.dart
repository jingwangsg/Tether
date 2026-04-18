import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
// ignore: implementation_imports
import 'package:xterm/src/ui/render.dart' show RenderTerminal;
import 'package:xterm/xterm.dart' as xterm;

/// State machine for detecting long-press-drag on touch and deciding
/// when to override xterm's word-level selection with character-level.
class LongPressDragTracker {
  bool touchDown = false;
  DateTime? touchDownTime;
  Offset? lastTouchGlobalPos;
  bool longPressDragActive = false;

  /// Minimum hold duration to distinguish long press from double tap.
  static const holdThreshold = Duration(milliseconds: 400);

  bool get selectionGestureActive => touchDown && longPressDragActive;

  void onPointerDown(Offset globalPos) {
    touchDown = true;
    touchDownTime = DateTime.now();
    lastTouchGlobalPos = globalPos;
    longPressDragActive = false;
  }

  void onPointerMove(Offset globalPos) {
    if (!touchDown) return;
    lastTouchGlobalPos = globalPos;
  }

  void onPointerUpOrCancel() {
    touchDown = false;
    longPressDragActive = false;
    touchDownTime = null;
    lastTouchGlobalPos = null;
  }

  /// Called when a selection change is detected on the terminal controller.
  /// Returns true if the selection should be overridden with character-level.
  bool onSelectionChanged({required bool hasSelection}) {
    if (!touchDown) return false;

    if (!hasSelection) {
      longPressDragActive = false;
      return false;
    }

    if (!longPressDragActive) {
      final held =
          touchDownTime != null
              ? DateTime.now().difference(touchDownTime!)
              : Duration.zero;
      if (held >= holdThreshold) {
        longPressDragActive = true;
      }
      return false;
    }

    return lastTouchGlobalPos != null;
  }
}

/// Android touch-selection adapter for the terminal.
///
/// This keeps the app-level long-press-drag override that converts xterm's
/// word-level touch expansion into character-level selection, but intentionally
/// renders no draggable handles or floating toolbar.
class SelectionHandlesOverlay extends StatefulWidget {
  final xterm.TerminalController terminalController;
  final GlobalKey<xterm.TerminalViewState> xtermViewKey;
  final ValueChanged<bool> onSelectionGestureActiveChanged;
  final Widget child;

  const SelectionHandlesOverlay({
    super.key,
    required this.terminalController,
    required this.xtermViewKey,
    required this.onSelectionGestureActiveChanged,
    required this.child,
  });

  @override
  State<SelectionHandlesOverlay> createState() =>
      _SelectionHandlesOverlayState();
}

class _SelectionHandlesOverlayState extends State<SelectionHandlesOverlay> {
  final LongPressDragTracker _dragTracker = LongPressDragTracker();
  bool _overridingSelection = false;
  Offset? _longPressAnchorLocal;

  @override
  void initState() {
    super.initState();
    widget.terminalController.addListener(_onSelectionChanged);
  }

  @override
  void didUpdateWidget(SelectionHandlesOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.terminalController, widget.terminalController)) {
      oldWidget.terminalController.removeListener(_onSelectionChanged);
      widget.terminalController.addListener(_onSelectionChanged);
    }
    _notifySelectionGestureActivity();
  }

  @override
  void dispose() {
    widget.terminalController.removeListener(_onSelectionChanged);
    widget.onSelectionGestureActiveChanged(false);
    super.dispose();
  }

  void _notifySelectionGestureActivity() {
    widget.onSelectionGestureActiveChanged(_dragTracker.selectionGestureActive);
  }

  void _onSelectionChanged() {
    if (!mounted) return;

    if (_overridingSelection) {
      _overridingSelection = false;
      _notifySelectionGestureActivity();
      return;
    }

    final hasSelection = widget.terminalController.selection != null;
    final shouldOverride = _dragTracker.onSelectionChanged(
      hasSelection: hasSelection,
    );

    if (!hasSelection) {
      _longPressAnchorLocal = null;
    }

    if (_dragTracker.longPressDragActive && _longPressAnchorLocal == null) {
      final rt = _getRenderTerminal();
      final touchPos = _dragTracker.lastTouchGlobalPos;
      if (rt != null && touchPos != null) {
        _longPressAnchorLocal = rt.globalToLocal(touchPos);
      }
    }

    _notifySelectionGestureActivity();

    if (!shouldOverride) return;

    final rt = _getRenderTerminal();
    final touchPos = _dragTracker.lastTouchGlobalPos;
    final anchor = _longPressAnchorLocal;
    if (rt == null || touchPos == null || anchor == null) return;

    _overridingSelection = true;
    rt.selectCharacters(anchor, rt.globalToLocal(touchPos));
  }

  RenderTerminal? _getRenderTerminal() {
    final viewState = widget.xtermViewKey.currentState;
    if (viewState == null) return null;
    try {
      return viewState.renderTerminal;
    } catch (_) {
      return null;
    }
  }

  void _resetTracking() {
    _dragTracker.onPointerUpOrCancel();
    _longPressAnchorLocal = null;
    _notifySelectionGestureActivity();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (event) {
        if (event.kind != PointerDeviceKind.touch) return;
        _dragTracker.onPointerDown(event.position);
        _longPressAnchorLocal = null;
        _notifySelectionGestureActivity();
      },
      onPointerMove: (event) {
        if (event.kind != PointerDeviceKind.touch) return;
        _dragTracker.onPointerMove(event.position);
      },
      onPointerUp: (event) {
        if (event.kind != PointerDeviceKind.touch) return;
        _resetTracking();
      },
      onPointerCancel: (event) {
        if (event.kind != PointerDeviceKind.touch) return;
        _resetTracking();
      },
      child: widget.child,
    );
  }
}
