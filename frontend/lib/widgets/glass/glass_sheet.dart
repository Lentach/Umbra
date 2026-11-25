import 'package:flutter/material.dart';

import 'glass_surface.dart';

/// The ONE way to open a Liquid Glass modal bottom sheet (accepted spec §1:
/// sheets are glass chrome). Transparent route background so the blur
/// samples the content behind; top-rounded 26 glass surface; the builder's
/// content should include its own `SafeArea(top: false)` if it reaches the
/// bottom edge.
Future<T?> showGlassSheet<T>(
  BuildContext context, {
  bool isScrollControlled = false,

  /// Spec §7 per-surface fallback: media-dense sheets (large grids) render
  /// on the opaque surface — a near-fully-covered backdrop blur buys nothing.
  bool opaque = false,

  /// `false` for a sheet that must not be swiped away (a pop from the drag
  /// bypasses `PopScope`).
  bool enableDrag = true,
  required WidgetBuilder builder,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: isScrollControlled,
    enableDrag: enableDrag,
    backgroundColor: Colors.transparent,
    builder: (ctx) => GlassSurface(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
      shadow: false,
      forceOpaque: opaque,
      child: builder(ctx),
    ),
  );
}
