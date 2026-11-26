import 'package:flutter/material.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';

import '../l10n/app_localizations.dart';
import '../widgets/link_qr_scanner.dart';

/// What the scanner route hands back to the ceremony screen that pushed it.
sealed class LinkScanResult {
  const LinkScanResult();
}

/// A QR was decoded; [code] is the raw text (callers normalise with
/// `extractLinkCode`).
class LinkScanCode extends LinkScanResult {
  const LinkScanCode(this.code);
  final String code;
}

/// The scanner cannot run here (no camera API, permission denied, no
/// decoder) — the caller opens the typed field and says why.
class LinkScanUnsupported extends LinkScanResult {
  const LinkScanUnsupported();
}

/// The user chose to type the code instead.
class LinkScanManual extends LinkScanResult {
  const LinkScanManual();
}

/// Route name for the scanner surface.
///
/// While the device-link gate is up, `AuthGate` sweeps page routes off the
/// root navigator so nothing can cover it (`main.dart`, issue #175). The
/// ceremony's OWN scanner is the one page route that must survive that sweep,
/// and this name is how the sweep recognises it.
const String kLinkScanRouteName = 'link-scan';

/// The §5.1 scanner as its OWN surface (Signal / WhatsApp / Telegram shape):
/// the camera fills the viewport, a scrim with a square window says where to
/// aim, one caption, an X, and the typed fallback. Pops a [LinkScanResult],
/// or null when the user leaves.
///
/// The camera is content, not chrome: no entrance animation (playbook §7
/// banned zone), and the decoded frame is handed over the moment it lands —
/// the human's next step is the SAS comparison, not an OK button.
class LinkScanScreen extends StatefulWidget {
  const LinkScanScreen({super.key, this.scannerBuilder});

  /// Test seam, same shape as the ceremony screens': a fake that fires
  /// [LinkQrScanner]'s callbacks without a camera. Null = the real scanner.
  final Widget Function({
    required void Function(String code) onCode,
    VoidCallback? onUnsupported,
  })?
  scannerBuilder;

  @override
  State<LinkScanScreen> createState() => _LinkScanScreenState();
}

class _LinkScanScreenState extends State<LinkScanScreen> {
  bool _popped = false;

  /// One exit, whichever callback or button fires first. The scanner may
  /// report "unsupported" from a build-phase errorBuilder, so the pop is
  /// deferred to the next frame in every case. A route already leaving (the
  /// user pressed back while the camera still sees a QR) is no longer
  /// current: popping then would close the route BELOW the scanner.
  void _finish(LinkScanResult? result) {
    if (_popped) return;
    _popped = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        Navigator.of(context).pop(result);
      }
    });
  }

  Widget _buildScanner() {
    final builder = widget.scannerBuilder;
    if (builder != null) {
      return builder(
        onCode: (code) => _finish(LinkScanCode(code)),
        onUnsupported: () => _finish(const LinkScanUnsupported()),
      );
    }
    return LinkQrScanner(
      onCode: (code) => _finish(LinkScanCode(code)),
      onUnsupported: () => _finish(const LinkScanUnsupported()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final padding = MediaQuery.paddingOf(context);
    // The camera preview is the only thing that must be seen through the
    // scrim; every control sits on the scrim itself, so the text colour is
    // fixed against black rather than themed (functional, not styling).
    const onScrim = Colors.white;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          _buildScanner(),
          // The scrim is paint only: it must never sit between a pointer and
          // the camera layer on web, where the preview is a platform view.
          IgnorePointer(
            child: CustomPaint(
              painter: _ScanScrimPainter(accent: colors.primary),
            ),
          ),
          // Controls over a platform view need the interceptor, or the DOM
          // <video> receives the tap (frontend/CLAUDE.md §7).
          Positioned(
            top: padding.top + 8,
            left: 8,
            child: PointerInterceptor(
              child: IconButton(
                key: const Key('link-scan-close'),
                icon: const Icon(Icons.close, color: onScrim, size: 28),
                tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                onPressed: () => _finish(null),
              ),
            ),
          ),
          Positioned(
            left: 24,
            right: 24,
            bottom: padding.bottom + 24,
            child: PointerInterceptor(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    l10n.linkScanHint,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: onScrim,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextButton(
                    key: const Key('link-scan-manual'),
                    onPressed: () => _finish(const LinkScanManual()),
                    style: TextButton.styleFrom(foregroundColor: onScrim),
                    child: Text(l10n.linkEnterCodeManually),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Dark scrim with a centred square window and four bracket corners. The
/// window is the shorter viewport side × 0.68, a common size across the
/// reference scanners; the scanner itself decodes the whole frame, the window
/// only tells the human where to aim.
class _ScanScrimPainter extends CustomPainter {
  const _ScanScrimPainter({required this.accent});

  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final side = size.shortestSide * 0.68;
    final window = Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2 - size.height * 0.04),
      width: side,
      height: side,
    );
    final rounded = RRect.fromRectAndRadius(window, const Radius.circular(16));

    final scrim = Path()
      ..addRect(Offset.zero & size)
      ..addRRect(rounded)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(scrim, Paint()..color = const Color(0x99000000));

    final bracket = Paint()
      ..color = accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    const arm = 28.0;
    const r = 16.0;
    void corner(Offset at, int dx, int dy) {
      final path = Path()
        ..moveTo(at.dx, at.dy + dy * arm)
        ..lineTo(at.dx, at.dy + dy * r)
        ..arcToPoint(
          Offset(at.dx + dx * r, at.dy),
          radius: const Radius.circular(r),
          clockwise: dx * dy > 0,
        )
        ..lineTo(at.dx + dx * arm, at.dy);
      canvas.drawPath(path, bracket);
    }

    corner(window.topLeft, 1, 1);
    corner(window.topRight, -1, 1);
    corner(window.bottomLeft, 1, -1);
    corner(window.bottomRight, -1, -1);
  }

  @override
  bool shouldRepaint(_ScanScrimPainter oldDelegate) =>
      oldDelegate.accent != accent;
}
