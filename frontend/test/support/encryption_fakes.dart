import 'package:fireplace/providers/encryption_provider.dart';

/// An [EncryptionProvider] with no service behind it and nothing overridden:
/// for a screen that only needs one in the tree. A test whose fake overrides
/// something declares its own subclass next to that test.
class FakeEncryptionProvider extends EncryptionProvider {}
