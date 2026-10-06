import 'package:flutter/widgets.dart';

import 'app_localizations.dart';

/// `context.l10n.actionPlay` instead of `AppLocalizations.of(context)!...`.
extension L10nAccess on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);
}
