/// `m:ss` for a length in whole [seconds]; minutes are not wrapped at the
/// hour (`75:03`).
String formatClock(int seconds) {
  final minutes = seconds ~/ 60;
  final secs = seconds % 60;
  return '$minutes:${secs.toString().padLeft(2, '0')}';
}
