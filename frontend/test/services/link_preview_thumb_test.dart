import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/services/box/box_envelope.dart';
import 'package:fireplace/services/link_preview_thumb.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/utils/e2e_envelope.dart';
import 'package:fireplace/widgets/message/text_message_content.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import '../support/profile_photo_fakes.dart';

String b64(Uint8List bytes) => base64Encode(bytes);

/// A noisy photo-like image: does not compress to nothing.
Uint8List noisyPng(int width, int height) {
  final random = Random(7);
  final image = img.Image(width: width, height: height);
  for (final p in image) {
    p.setRgb(random.nextInt(256), random.nextInt(256), random.nextInt(256));
  }
  return Uint8List.fromList(img.encodePng(image));
}

void main() {
  final thumb = b64(jpegHeader(320, 168));

  group('envelope carries img, never imageUrl', () {
    test('builds and parses img; a legacy imageUrl is ignored', () {
      final built = E2eEnvelope.build(
        'https://a.example',
        linkPreview: {'url': 'https://a.example', 'title': 'A', 'img': thumb},
      );
      final parsed = E2eEnvelope.parse(jsonEncode(built));
      expect(parsed.linkPreviewImage, thumb);
      expect(parsed.linkPreviewTitle, 'A');

      final legacy = E2eEnvelope.parse(
        jsonEncode(
          E2eEnvelope.build(
            'x',
            linkPreview: {
              'url': 'https://a.example',
              'title': 'A',
              'imageUrl': 'https://tracker.example/p.png',
            },
          ),
        ),
      );
      expect(legacy.linkPreviewImage, isNull);
      expect(legacy.linkPreviewUrl, 'https://a.example');
    });
  });

  group('boxEnvelope drops img first, then the preview', () {
    ({String json, String copyJson, Map<String, String?>? linkPreview}) seal(
      Map<String, String?> preview, {
      String text = 'see https://a.example',
    }) => boxEnvelope(
      text,
      senderListInfo: const {'ownVersion': 1},
      msgId: 'm' * 64,
      sentAt: DateTime.utc(2026, 11, 17),
      sentTo: 0x7fffffff,
      linkPreview: preview,
    );

    Map<String, dynamic> lp(String json) =>
        (jsonDecode(json) as Map<String, dynamic>)['linkPreview']
            as Map<String, dynamic>;

    test('with room, the image rides and both envelopes match', () {
      final built = seal({'url': 'https://a.example', 'title': 'A', 'img': thumb});
      expect(built.linkPreview?['img'], thumb);
      expect(lp(built.json), lp(built.copyJson));
    });

    test('too big with img: the image goes, title and url stay', () {
      final big = b64(Uint8List(kBoxEnvelopeMaxBytes));
      final built = seal({'url': 'https://a.example', 'title': 'A', 'img': big});
      expect(built.linkPreview, {'url': 'https://a.example', 'title': 'A'});
      expect(lp(built.json), {'url': 'https://a.example', 'title': 'A'});
      expect(lp(built.copyJson), lp(built.json));
    });

    test('too big without img: the whole preview goes from both', () {
      final built = seal({
        'url': 'https://a.example',
        'title': 't' * 20000,
        'img': thumb,
      });
      expect(built.linkPreview, isNull);
      for (final json in [built.json, built.copyJson]) {
        expect(jsonDecode(json), isNot(contains('linkPreview')));
        expect(utf8.encode(json).length, lessThanOrEqualTo(kBoxEnvelopeMaxBytes));
      }
    });
  });

  group('receive validation: a bad image drops only the image', () {
    test('a sound JPEG within the bounds is kept', () {
      expect(LinkPreviewThumb.decode(thumb), isNotNull);
      expect(LinkPreviewThumb.validated(thumb), thumb);
    });

    test('bad base64, non-JPEG, oversize side and oversize bytes are refused', () {
      expect(LinkPreviewThumb.decode('***not base64***'), isNull);
      expect(LinkPreviewThumb.decode(b64(Uint8List.fromList([1, 2, 3, 4, 5]))), isNull);
      expect(LinkPreviewThumb.decode(b64(jpegHeader(321, 100))), isNull);
      expect(LinkPreviewThumb.decode(b64(jpegHeader(100, 4000))), isNull);
      final bloated = jpegHeader(
        64,
        64,
        tail: List.filled(LinkPreviewThumb.kMaxAcceptedBytes, 0),
      );
      expect(LinkPreviewThumb.decode(b64(bloated)), isNull);
      expect(LinkPreviewThumb.decode(null), isNull);
      expect(LinkPreviewThumb.decode(''), isNull);
    });
  });

  group('scale', () {
    test('a large image becomes a sound JPEG within budget', () async {
      final out = await LinkPreviewThumb.scale(noisyPng(1600, 900));
      expect(out, isNotNull);
      final bytes = base64Decode(out!);
      expect(bytes.length, lessThanOrEqualTo(LinkPreviewThumb.kMaxBytes));
      expect(LinkPreviewThumb.decode(out), isNotNull);
    });

    test('bytes that are not an image give null', () async {
      expect(await LinkPreviewThumb.scale(Uint8List.fromList([1, 2, 3])), isNull);
    });
  });

  group('TextMessageContent renders only the carried bytes', () {
    Widget wrap(MessageModel m) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: RpgTheme.themeDataLight,
      home: Scaffold(
        body: TextMessageContent(
          message: m,
          isMine: false,
          textColor: Colors.black,
          isDark: false,
          maxWidth: 280,
        ),
      ),
    );

    MessageModel msg({String? image}) => MessageModel(
      id: 1,
      content: 'https://a.example',
      senderId: 1,
      senderUsername: 'alice',
      conversationId: 1,
      createdAt: DateTime(2026, 11, 17),
      linkPreviewUrl: 'https://a.example',
      linkPreviewTitle: 'Title',
      linkPreviewImage: image,
    );

    bool hasNetworkImage(WidgetTester tester) => tester
        .widgetList<Image>(find.byType(Image))
        .any((i) => i.image is NetworkImage);

    testWidgets('a legacy record (json with only linkPreviewImageUrl) loads nothing',
        (tester) async {
      final legacy = MessageModel.fromJson({
        'id': 1,
        'content': 'https://a.example',
        'senderId': 1,
        'senderUsername': 'alice',
        'conversationId': 1,
        'createdAt': '2026-11-17T10:00:00.000Z',
        'linkPreviewUrl': 'https://a.example',
        'linkPreviewTitle': 'Title',
        'linkPreviewImageUrl': 'https://tracker.example/p.png',
      });
      await tester.pumpWidget(wrap(legacy));
      expect(find.text('Title'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      expect(hasNetworkImage(tester), isFalse);
    });

    testWidgets('a valid thumbnail renders from memory, never the network',
        (tester) async {
      await tester.pumpWidget(wrap(msg(image: thumb)));
      final images = tester.widgetList<Image>(find.byType(Image)).toList();
      expect(images, hasLength(1));
      expect(images.single.image, isA<ResizeImage>());
      expect(hasNetworkImage(tester), isFalse);
    });

    testWidgets('an invalid thumbnail shows the title card without an image',
        (tester) async {
      await tester.pumpWidget(wrap(msg(image: b64(Uint8List.fromList([9, 9, 9, 9])))));
      expect(find.text('Title'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });
  });
}
