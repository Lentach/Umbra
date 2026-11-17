import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:fireplace/services/link_preview_service.dart';
import 'package:fireplace/services/link_preview_thumb.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;

Uint8List png() {
  final r = Random(3);
  final image = img.Image(width: 640, height: 400);
  for (final p in image) {
    p.setRgb(r.nextInt(256), r.nextInt(256), r.nextInt(256));
  }
  return Uint8List.fromList(img.encodePng(image));
}

http.StreamedResponse res(
  int status,
  Stream<List<int>> body, {
  Map<String, String> headers = const {},
}) => http.StreamedResponse(body, status, headers: headers);

void main() {
  const page = 'https://a.example/p';
  final bytes = png();

  test('a public https image becomes a sound thumbnail', () async {
    final client = MockClient.streaming(
      (req, _) async => res(
        200,
        Stream.value(bytes),
        headers: {'content-type': 'image/png'},
      ),
    );
    final out = await LinkPreviewService.fetchThumbnail(
      '/og.png',
      page,
      client: client,
    );
    expect(LinkPreviewThumb.decode(out), isNotNull);
  });

  test('every redirect hop is re-checked; http and private hops are refused',
      () async {
    for (final target in ['http://cdn.a.example/x.png', 'https://127.0.0.1/x.png']) {
      final seen = <Uri>[];
      final client = MockClient.streaming((req, _) async {
        seen.add(req.url);
        return res(302, const Stream.empty(), headers: {'location': target});
      });
      expect(
        await LinkPreviewService.fetchThumbnail('https://a.example/o.png', page,
            client: client),
        isNull,
      );
      expect(seen, hasLength(1), reason: '$target never requested');
    }
  });

  test('a public redirect is followed, a loop is cut', () async {
    var n = 0;
    final ok = MockClient.streaming((req, _) async {
      n++;
      return req.url.host == 'a.example'
          ? res(302, const Stream.empty(),
              headers: {'location': 'https://cdn.example/x.png'})
          : res(200, Stream.value(bytes), headers: {'content-type': 'image/png'});
    });
    expect(
      await LinkPreviewService.fetchThumbnail('https://a.example/o.png', page,
          client: ok),
      isNotNull,
    );
    expect(n, 2);
    var loops = 0;
    final loop = MockClient.streaming((req, _) async {
      loops++;
      return res(302, const Stream.empty(),
          headers: {'location': 'https://a.example/again'});
    });
    expect(
      await LinkPreviewService.fetchThumbnail('https://a.example/o.png', page,
          client: loop),
      isNull,
    );
    expect(loops, lessThanOrEqualTo(4));
  });

  test('a non-image content type is refused', () async {
    final client = MockClient.streaming(
      (req, _) async =>
          res(200, Stream.value(bytes), headers: {'content-type': 'text/html'}),
    );
    expect(
      await LinkPreviewService.fetchThumbnail('https://a.example/o', page,
          client: client),
      isNull,
    );
  });

  test('a body over the cap is refused', () async {
    final chunk = Uint8List(LinkPreviewService.kMaxImageDownloadBytes ~/ 2);
    final client = MockClient.streaming(
      (req, _) async => res(
        200,
        Stream.fromIterable([chunk, chunk, Uint8List(1)]),
        headers: {'content-type': 'image/png'},
      ),
    );
    expect(
      await LinkPreviewService.fetchThumbnail('https://a.example/o.png', page,
          client: client),
      isNull,
    );
  });

  test('one overall deadline cuts a slow trickling stream', () async {
    final trickle = Stream.periodic(
      const Duration(milliseconds: 60),
      (_) => <int>[1],
    );
    final client = MockClient.streaming(
      (req, _) async =>
          res(200, trickle, headers: {'content-type': 'image/png'}),
    );
    final watch = Stopwatch()..start();
    final out = await LinkPreviewService.fetchThumbnail(
      'https://a.example/o.png',
      page,
      client: client,
      budget: const Duration(milliseconds: 400),
    );
    expect(out, isNull);
    expect(watch.elapsedMilliseconds, lessThan(1500));
  });

  group('web send branch: imageData becomes img', () {
    test('scales the backend bytes and drops imageUrl/imageData', () async {
      final out = await LinkPreviewThumb.fromBackend({
        'url': 'https://a.example',
        'title': 'T',
        'imageData': (await LinkPreviewThumb.scale(bytes))!,
      });
      expect(out!.keys, unorderedEquals(['url', 'title', 'img']));
      expect(LinkPreviewThumb.decode(out['img']), isNotNull);
    });

    test('bad bytes keep the title; nothing at all gives null', () async {
      final titled = await LinkPreviewThumb.fromBackend(
        {'url': 'u', 'title': 'T', 'imageData': '***'},
      );
      expect(titled, {'url': 'u', 'title': 'T', 'img': null});
      expect(
        await LinkPreviewThumb.fromBackend(
          {'url': 'u', 'title': null, 'imageData': 'AAAA'},
        ),
        isNull,
      );
    });
  });
}
