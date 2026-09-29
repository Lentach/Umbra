import 'dart:typed_data';

import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/services/box/box_outbox.dart';
import 'package:fireplace/services/box/box_wire.dart';
import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:flutter_test/flutter_test.dart';

/// Only the coverage half matters here: with no device list held, a peer is
/// box-covered when its contact record holds an address (`addressesFor`).
class _Outbox implements BoxOutbox {
  final Map<int, Map<int, ContactOutbound>> addresses = {};

  @override
  Map<int, ContactOutbound> addressesFor(int peerUserId) =>
      addresses[peerUserId] ?? const {};

  @override
  Map<int, ContactOutbound> siblingAddresses() => const {};

  @override
  Iterable<int> coveredPeers() => addresses.keys;

  @override
  Future<bool> deliver(
    ContactOutbound to,
    Uint8List body, {
    BoxSendMode? mode,
  }) async => true;

  @override
  Future<int?> nextLocalId() async => null;

  @override
  Future<BoxResult<BoxMediaRef>> uploadMedia(
    ContactOutbound to,
    Uint8List framed,
  ) async => throw UnimplementedError();

  @override
  Future<BoxResult<Uint8List>> downloadMedia(Uint8List id) async =>
      throw UnimplementedError();
}

ContactOutbound _address(int device) =>
    ContactOutbound(peerDeviceId: device, sid: 'sid-$device', sealPub: 'pub');

void main() {
  late List<String> emitted;
  late MessagingProvider provider;

  setUp(() {
    emitted = [];
    provider = MessagingProvider()
      ..setCurrentUserId(1)
      ..setEmitCallback((event, _) => emitted.add(event));
  });

  test(
    'typing to a box-covered peer never goes out on the account socket '
    '(decision 33: no typing on box chats until the E2E switch, item 8)',
    () {
      provider
        ..boxOutbox = (_Outbox()..addresses[2] = {1: _address(1)})
        ..sendTypingIndicator(2, 10);

      expect(emitted, isEmpty);
    },
  );

  test('typing to a peer the box does not cover still emits `typing`', () {
    provider
      ..boxOutbox = (_Outbox()..addresses[2] = {1: _address(1)})
      ..sendTypingIndicator(3, 11);

    expect(emitted, ['typing']);
  });

  test('with no box session at all, typing emits as before', () {
    provider.sendTypingIndicator(3, 11);

    expect(emitted, ['typing']);
  });

  test(
    'the voice-recording indicator follows the same rule: none to a '
    'box-covered peer, `recordingVoice` with its payload to an uncovered one',
    () {
      final payloads = <Object?>[];
      provider
        ..setEmitCallback((event, data) {
          emitted.add(event);
          payloads.add(data);
        })
        ..boxOutbox = (_Outbox()..addresses[2] = {1: _address(1)})
        ..sendRecordingVoiceIndicator(2, 10, isRecording: true)
        ..sendRecordingVoiceIndicator(2, 10, isRecording: false);
      expect(emitted, isEmpty);

      provider.sendRecordingVoiceIndicator(3, 11, isRecording: true);
      expect(emitted, ['recordingVoice']);
      expect(payloads.single, {
        'recipientId': 3,
        'conversationId': 11,
        'isRecording': true,
      });
    },
  );
}
