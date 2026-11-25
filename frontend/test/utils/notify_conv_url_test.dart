import 'package:fireplace/utils/notify_conv_url.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // The push service worker opens `/?notify_conv=<id>` with nothing else in
  // the query, so this is the URL every notification tap produces.
  test('removes the whole query when the chat id was its only parameter', () {
    expect(
      notifyConvStrippedUrl(Uri.parse('https://umbra.invalid/?notify_conv=42')),
      'https://umbra.invalid/',
    );
  });

  test('keeps the path, port and fragment of a notification URL', () {
    expect(
      notifyConvStrippedUrl(
        Uri.parse('http://localhost:8080/app/?notify_conv=42#/chats'),
      ),
      'http://localhost:8080/app/#/chats',
    );
  });

  test('keeps the other parameters', () {
    expect(
      notifyConvStrippedUrl(
        Uri.parse('https://umbra.invalid/?a=1&notify_conv=42&b=2'),
      ),
      'https://umbra.invalid/?a=1&b=2',
    );
  });
}
