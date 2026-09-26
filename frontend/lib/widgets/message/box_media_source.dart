import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../providers/messaging_provider.dart';
import '../../services/box/box_media_url.dart';
import '../../utils/encrypted_media_loader.dart';

/// What a media widget hands `loadDecryptedMediaBytes` for [url] (item 3 /
/// media wiring): the signed-in account's box attachment copies, through
/// the [MessagingProvider] that owns them, for a `box:` url; null for any
/// other, so an old-path bubble never needs the provider.
BoxCiphertextSource? boxMediaSourceFor(BuildContext context, String? url) =>
    isBoxMediaUrl(url)
    ? context.read<MessagingProvider>().boxMediaCiphertext
    : null;
