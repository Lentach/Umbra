import 'dart:ui';

import 'package:fireplace/l10n/app_localizations.dart';

/// The English strings the app shows under test (widget tests run in `en`).
/// Locate and assert UI text through these getters, never an English literal:
/// a reworded ARB value must not turn a test red.
final AppLocalizations l10n = lookupAppLocalizations(const Locale('en'));
