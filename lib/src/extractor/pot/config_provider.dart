/// Config-based PO Token provider (`CLIENT.CONTEXT+TOKEN`).
library pot_config_provider;

import 'models.dart';
import 'provider.dart';
import 'utils.dart';

class ConfigPoTokenProvider implements PoTokenProvider {
  final Map<String, Map<PoTokenContext, String>> tokens;

  ConfigPoTokenProvider(List<String> configs)
      : tokens = parsePoTokenConfigs(configs);

  @override
  String get name => 'config';

  @override
  bool isAvailable() => tokens.isNotEmpty;

  @override
  Future<PoTokenResponse?> requestPot(PoTokenRequest request) async {
    final token = lookupConfiguredPoToken(
      tokens,
      client: request.internalClientName,
      context: request.context,
    );
    if (token == null) {
      throw PoTokenProviderRejected(
        'No configured token for ${request.internalClientName}.${request.context.value}',
      );
    }
    return PoTokenResponse(poToken: token);
  }
}
