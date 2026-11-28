import 'package:fireplace/services/encryption_service.dart';

extension VerifyPinned on EncryptionService {
  /// Marks [peerId] verified against the key pinned right now (a test that
  /// compared the key it is about to rely on).
  Future<bool> verifyPinned(int peerId) async => markPeerVerified(
    peerId,
    expectedIdentityBase64: (await peerTofuIdentityBase64(peerId))!,
  );
}
