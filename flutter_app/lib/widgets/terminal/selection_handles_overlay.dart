import 'dart:math' as math;

import 'package:flutter/material.dart';
// ignore: implementation_imports
import 'package:xterm/src/ui/render.dart' show RenderTerminal;
import 'package:xterm/xterm.dart' as xterm;

/// Android-style draggable selection handles overlay for the terminal.
///
/// Wraps a child [xterm.TerminalView] in a [Stack] when a selection exists,
/// showing two teardrop drag handles at the selection boundaries and a
/// floating Copy/Paste toolbar above the selection midpoint.
class SelectionHandlesOverlay extends StatefulWidget {
  final xterm.TerminalController terminalController;
  final GlobalKey<xterm.TerminalViewState> xtermViewKey;
  final xterm.Terminal terminal;
  final VoidCallback onCopy;
  final VoidCallback onPaste;
  final ScrollController scrollController;
  final Widget child;

  const SelectionHandlesOverlay({
    super.key,
    required this.terminalController,
    required this.xtermViewKey,
    required this.terminal,
    required this.onCopy,
    required this.onPaste,
    required this.scrollController,
    required this.child,
  });

  @override
  State<SelectionHandlesOverlay> createState() =>
      _SelectionHandlesOverlayState();
}

class _SelectionHandlesOverlayState extends State<SelectionHandlesOverlay> {
  bool _isDragging = false;

  @override
  void initState() {
    super.initState();
    widget.terminalController.addListener(_onSelectionChanged);
    widget.scrollController.addListener(_onScrollChanged);
  }

  @override
  void didUpdateWidget(SelectionHandlesOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.terminalController, widget.terminalController)) {
      oldWidget.terminalController.removeListener(_onSelectionChanged);
      widget.terminalController.addListener(_onSelectionChanged);
    }
    if (!identical(oldWidget.scrollController, widget.scrollController)) {
      oldWidget.scrollController.removeListener(_onScrollChanged);
      widget.scrollController.addListener(_onScrollChanged);
    }
  }

  @override
  void dispose() {
    widget.terminalController.removeListener(_onSelectionChanged);
    widget.scrollController.removeListener(_onScrollChanged);
    super.dispose();
  }

  void _onSelectionChanged() {
    // Rebuild to update handle positions or show/hide the overlay.
    if (mounted) setState(() {});
  }

  void _onScrollChanged() {
    // Reposition handles when the terminal scrolls.
    if (mounted && widget.terminalController.selection != null) {
      setState(() {});
    }
  }

  RenderTerminal? _getRenderTerminal() {
    final viewState = widget.xtermViewKey.currentState;
    if (viewState == null) return null;
    try {
      return viewState.renderTerminal;
    } catch (_) {
      // renderTerminal accesses the render object which may not exist yet.
      return null;
    }
  }

  void _onHandleDragStart() {
    setState(() => _isDragging = true);
  }

  void _onHandleDragEnd() {
    setState(() => _isDragging = false);
  }

  /// Convert a local position within our Stack to a [xterm.CellOffset] using
  /// the RenderTerminal's coordinate system.
  xterm.CellOffset? _localToCellOffset(
    Offset localPosition,
    RenderTerminal renderTerminal,
  ) {
    // Stack local -> global -> RenderTerminal local
    final stackRenderBox = context.findRenderObject() as RenderBox?;
    if (stackRenderBox == null) return null;
    final global = stackRenderBox.localToGlobal(localPosition);
    final rtLocal = renderTerminal.globalToLocal(global);
    return renderTerminal.getCellOffset(rtLocal);
  }

  void _onBaseHandleDrag(DragUpdateDetails details, Offset handlePosition) {
    final renderTerminal = _getRenderTerminal();
    if (renderTerminal == null) return;

    final selection = widget.terminalController.selection;
    if (selection == null) return;

    final newPos = handlePosition + details.delta;
    final cellOffset = _localToCellOffset(newPos, renderTerminal);
    if (cellOffset == null) return;

    // Keep the current extent, update the base.
    final normalized = selection.normalized;
    final newBase = widget.terminal.buffer.createAnchorFromOffset(cellOffset);
    final newExtent =
        widget.terminal.buffer.createAnchorFromOffset(normalized.end);
    widget.terminalController.setSelection(newBase, newExtent);
  }

  void _onExtentHandleDrag(DragUpdateDetails details, Offset handlePosition) {
    final renderTerminal = _getRenderTerminal();
    if (renderTerminal == null) return;

    final selection = widget.terminalController.selection;
    if (selection == null) return;

    final newPos = handlePosition + details.delta;
    final cellOffset = _localToCellOffset(newPos, renderTerminal);
    if (cellOffset == null) return;

    // Selection end is exclusive, so add 1 to x for inclusive feel.
    final adjustedOffset = xterm.CellOffset(cellOffset.x + 1, cellOffset.y);

    final normalized = selection.normalized;
    final newBase =
        widget.terminal.buffer.createAnchorFromOffset(normalized.begin);
    final newExtent =
        widget.terminal.buffer.createAnchorFromOffset(adjustedOffset);
    widget.terminalController.setSelection(newBase, newExtent);
  }

  @override
  Widget build(BuildContext context) {
    final selection = widget.terminalController.selection;
    if (selection == null) {
      return widget.child;
    }

    // Defer coordinate reading to after layout.
    return Stack(
      clipBehavior: Clip.none,
      children: [
        widget.child,
        _SelectionHandlesLayer(
          selection: selection,
          getRenderTerminal: _getRenderTerminal,
          isDragging: _isDragging,
          onBaseHandleDrag: _onBaseHandleDrag,
          onExtentHandleDrag: _onExtentHandleDrag,
          onDragStart: _onHandleDragStart,
          onDragEnd: _onHandleDragEnd,
          onCopy: () {
            widget.onCopy();
            widget.terminalController.clearSelection();
          },
          onPaste: () {
            widget.onPaste();
            widget.terminalController.clearSelection();
          },
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Internal layer widget that reads RenderTerminal coordinates post-layout.
// ---------------------------------------------------------------------------

class _SelectionHandlesLayer extends StatefulWidget {
  final xterm.BufferRange selection;
  final RenderTerminal? Function() getRenderTerminal;
  final bool isDragging;
  final void Function(DragUpdateDetails details, Offset handlePosition)
      onBaseHandleDrag;
  final void Function(DragUpdateDetails details, Offset handlePosition)
      onExtentHandleDrag;
  final VoidCallback onDragStart;
  final VoidCallback onDragEnd;
  final VoidCallback onCopy;
  final VoidCallback onPaste;

  const _SelectionHandlesLayer({
    required this.selection,
    required this.getRenderTerminal,
    required this.isDragging,
    required this.onBaseHandleDrag,
    required this.onExtentHandleDrag,
    required this.onDragStart,
    required this.onDragEnd,
    required this.onCopy,
    required this.onPaste,
  });

  @override
  State<_SelectionHandlesLayer> createState() => _SelectionHandlesLayerState();
}

class _SelectionHandlesLayerState extends State<_SelectionHandlesLayer> {
  Offset? _baseHandleOffset;
  Offset? _extentHandleOffset;

  @override
  void initState() {
    super.initState();
    _schedulePositionUpdate();
  }

  @override
  void didUpdateWidget(_SelectionHandlesLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    _schedulePositionUpdate();
  }

  void _schedulePositionUpdate() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _updatePositions();
    });
  }

  void _updatePositions() {
    final renderTerminal = widget.getRenderTerminal();
    if (renderTerminal == null) {
      setState(() {
        _baseHandleOffset = null;
        _extentHandleOffset = null;
      });
      return;
    }

    final normalized = widget.selection.normalized;
    final cellSize = renderTerminal.cellSize;

    // Base handle: bottom-left of first selected cell.
    final basePixel = renderTerminal.getOffset(normalized.begin);
    // Extent handle: bottom-right of last selected cell.
    final extentPixel = renderTerminal.getOffset(normalized.end);

    // Convert from RenderTerminal local to Stack local coordinates.
    final stackRenderBox = context.findRenderObject() as RenderBox?;
    if (stackRenderBox == null) return;

    final baseGlobal =
        renderTerminal.localToGlobal(basePixel + Offset(0, cellSize.height));
    final extentGlobal =
        renderTerminal.localToGlobal(extentPixel + Offset(0, cellSize.height));

    setState(() {
      _baseHandleOffset = stackRenderBox.globalToLocal(baseGlobal);
      _extentHandleOffset = stackRenderBox.globalToLocal(extentGlobal);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_baseHandleOffset == null || _extentHandleOffset == null) {
      return const SizedBox.shrink();
    }

    final base = _baseHandleOffset!;
    final extent = _extentHandleOffset!;

    final children = <Widget>[];

    // Floating toolbar — hidden during drag.
    if (!widget.isDragging) {
      final midX = (base.dx + extent.dx) / 2;
      // Position above the selection. Use the topmost handle y minus some
      // padding for the toolbar height.
      final topY = math.min(base.dy, extent.dy);
      children.add(
        Positioned(
          left: midX - 60, // roughly half the toolbar width
          top: topY - 48,
          child: _buildToolbar(),
        ),
      );
    }

    // Base (left) handle.
    children.add(
      Positioned(
        left: base.dx - _kHandleRadius,
        top: base.dy,
        child: _DragHandle(
          onDragStart: widget.onDragStart,
          onDragEnd: widget.onDragEnd,
          onDragUpdate: (details) =>
              widget.onBaseHandleDrag(details, base),
        ),
      ),
    );

    // Extent (right) handle.
    children.add(
      Positioned(
        left: extent.dx - _kHandleRadius,
        top: extent.dy,
        child: _DragHandle(
          onDragStart: widget.onDragStart,
          onDragEnd: widget.onDragEnd,
          onDragUpdate: (details) =>
              widget.onExtentHandleDrag(details, extent),
        ),
      ),
    );

    return Stack(clipBehavior: Clip.none, children: children);
  }

  Widget _buildToolbar() {
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton(
              onPressed: widget.onCopy,
              child: const Text('Copy'),
            ),
            TextButton(
              onPressed: widget.onPaste,
              child: const Text('Paste'),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Handle geometry constants
// ---------------------------------------------------------------------------

const double _kHandleRadius = 10.0;
const double _kHandleStemHeight = 8.0;
const double _kHandleStemWidth = 2.0;
const double _kHandleHitWidth = 20.0;
const double _kHandleHitHeight = 28.0;

// ---------------------------------------------------------------------------
// Draggable teardrop handle
// ---------------------------------------------------------------------------

class _DragHandle extends StatelessWidget {
  final VoidCallback onDragStart;
  final VoidCallback onDragEnd;
  final GestureDragUpdateCallback onDragUpdate;

  const _DragHandle({
    required this.onDragStart,
    required this.onDragEnd,
    required this.onDragUpdate,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (_) => onDragStart(),
      onPanUpdate: onDragUpdate,
      onPanEnd: (_) => onDragEnd(),
      onPanCancel: onDragEnd,
      child: SizedBox(
        width: _kHandleHitWidth,
        height: _kHandleHitHeight,
        child: CustomPaint(
          painter: _HandlePainter(),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Teardrop handle painter
// ---------------------------------------------------------------------------

class _HandlePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.blue
      ..style = PaintingStyle.fill;

    final centerX = size.width / 2;

    // Vertical stem from top to the circle.
    final stemRect = Rect.fromCenter(
      center: Offset(centerX, _kHandleStemHeight / 2),
      width: _kHandleStemWidth,
      height: _kHandleStemHeight,
    );
    canvas.drawRect(stemRect, paint);

    // Circle (teardrop body) below the stem.
    final circleCenter = Offset(centerX, _kHandleStemHeight + _kHandleRadius);
    canvas.drawCircle(circleCenter, _kHandleRadius, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
