/// PO Token provider interface.
library pot_provider;

import 'models.dart';

abstract class PoTokenProvider {
  String get name;

  /// Cheap availability check (no network preferred).
  bool isAvailable();

  /// Return null / throw [PoTokenProviderRejected] if unsupported.
  Future<PoTokenResponse?> requestPot(PoTokenRequest request);
}
