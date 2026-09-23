import 'box_signer.dart';

/// Off the web: pure Dart, one event-loop turn per signature, so a phone
/// re-signing a whole subscribe chunk keeps drawing frames.
BoxSigner platformBoxSigner() => const Ed25519BoxSigner(yields: true);
