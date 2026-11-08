import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';

import '../providers/messaging_provider.dart';
import '../services/profile/profile_photos.dart' show ProfilePhotoOutcome;

/// What the own user card does to the account's ONE profile photo
/// (decision 138): pick a file, make it the photo, or remove the photo.
/// A seam so the card can be tested without a platform picker or a box.
abstract interface class ProfilePhotoActions {
  /// The bytes of the image the user picked, or null when they backed out.
  Future<Uint8List?> pick();

  /// Makes [pickedImageBytes] the account's photo.
  Future<ProfilePhotoOutcome> set(Uint8List pickedImageBytes);

  /// Removes the account's photo.
  Future<ProfilePhotoOutcome> remove();
}

/// The real thing: the platform gallery picker and the messaging provider
/// (which scales, encrypts, uploads and announces the photo).
class MessagingProfilePhotoActions implements ProfilePhotoActions {
  const MessagingProfilePhotoActions(this._messaging);

  final MessagingProvider _messaging;

  @override
  Future<Uint8List?> pick() async {
    final image = await ImagePicker().pickImage(source: ImageSource.gallery);
    return image?.readAsBytes();
  }

  @override
  Future<ProfilePhotoOutcome> set(Uint8List pickedImageBytes) =>
      _messaging.setOwnProfilePhoto(pickedImageBytes);

  @override
  Future<ProfilePhotoOutcome> remove() => _messaging.removeOwnProfilePhoto();
}
