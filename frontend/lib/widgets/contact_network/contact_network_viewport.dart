part of '../contact_network_view.dart';

@immutable
class _VisibleRowRange {
  const _VisibleRowRange(this.first, this.last);

  const _VisibleRowRange.empty() : first = 0, last = -1;

  final int first;
  final int last;

  bool contains(int row) => row >= first && row <= last;

  bool get isEmpty => last < first;

  @override
  bool operator ==(Object other) =>
      other is _VisibleRowRange && other.first == first && other.last == last;

  @override
  int get hashCode => Object.hash(first, last);
}

/// Viewport windowing for [_ContactNetworkViewState]: which rows may fetch
/// avatars, which rows mount a visual hex, and scrolling a focused slot into
/// view. `_onScroll` stays in the class: it is registered and removed as a
/// tear-off, and extension tear-offs are never equal.
extension _ContactNetworkViewport on _ContactNetworkViewState {
  /// Last row whose avatars are allowed to fetch: everything on screen plus
  /// one row of lookahead, so a face decodes just before it scrolls in.
  int _visibleThroughRow(ContactHexLayoutResult layout, double fallbackHeight) {
    if (layout.slots.isEmpty) return 0;
    final attached = _scrollController.hasClients;
    final offset = attached ? _scrollController.position.pixels : 0.0;
    final viewport = attached
        ? _scrollController.position.viewportDimension
        : fallbackHeight;
    final bottom = offset + viewport + layout.rowPitch;
    final rows = ((bottom - layout.slots.first.dy) / layout.rowPitch).ceil();
    return rows.clamp(0, math.max(0, layout.rowCount - 1));
  }

  void _armVisibleRows() {
    final layout = _lastLayout;
    if (layout == null) return;
    final next = _visibleThroughRow(layout, 0);
    if (next > _armedThroughRow.value) _armedThroughRow.value = next;
  }

  _VisibleRowRange _visibleRowRange(
    ContactHexLayoutResult layout,
    double fallbackHeight,
  ) {
    if (layout.slots.isEmpty) return const _VisibleRowRange.empty();
    final attached = _scrollController.hasClients;
    final offset = attached ? _scrollController.position.pixels : 0.0;
    final viewport = attached
        ? _scrollController.position.viewportDimension
        : fallbackHeight;
    final firstRow =
        (((offset - layout.slots.first.dy) / layout.rowPitch).floor() - 1)
            .clamp(0, layout.rowCount - 1)
            .toInt();
    // Two rows of visual overscan prevent a blank edge during a fast fling.
    // Avatar arming keeps its tighter one-row lookahead, so the outermost
    // mounted row still proves that images remain lazy.
    final lastRow =
        (((offset + viewport - layout.slots.first.dy) / layout.rowPitch)
                    .ceil() +
                2)
            .clamp(firstRow, layout.rowCount - 1)
            .toInt();
    return _VisibleRowRange(firstRow, lastRow);
  }

  void _syncVisibleRows() {
    final layout = _lastLayout;
    if (layout == null) return;
    final next = _visibleRowRange(layout, _lastViewportHeight);
    if (next != _visibleRows.value) _visibleRows.value = next;
  }

  void _scheduleVisibleRowsSync() {
    if (_visibleRowsSyncScheduled) return;
    _visibleRowsSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _visibleRowsSyncScheduled = false;
      if (mounted) _syncVisibleRows();
    });
  }

  /// Scrolls a keyboard-focused slot's full visual rect into the viewport.
  void _revealSlot(ContactHexLayoutResult layout, Offset slot) {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final top = slot.dy - ContactHexLayout.hexRadius - 16;
    final bottom =
        slot.dy + ContactHexLayout.hexRadius + layout.labelHeight + 24;
    final viewTop = position.pixels;
    final viewBottom = viewTop + position.viewportDimension;
    double? target;
    if (top < viewTop) {
      target = top;
    } else if (bottom > viewBottom) {
      target = bottom - position.viewportDimension;
    }
    if (target != null) {
      position.moveTo(
        target.clamp(position.minScrollExtent, position.maxScrollExtent),
      );
    }
  }
}
