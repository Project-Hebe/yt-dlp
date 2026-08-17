/// PO Token director: cache + provider cascade.
library pot_director;

import 'package:http/http.dart' as http;

import '../../utils/logger.dart';
import 'bgutil_http_provider.dart';
import 'cache.dart';
import 'config_provider.dart';
import 'models.dart';
import 'provider.dart';
import 'utils.dart';

class PoTokenDirector {
  final List<PoTokenProvider> providers;
  final PoTokenMemoryCache cache;
  final FetchPotPolicy policy;

  PoTokenDirector({
    required this.providers,
    PoTokenMemoryCache? cache,
    this.policy = FetchPotPolicy.auto,
  }) : cache = cache ?? PoTokenMemoryCache();

  factory PoTokenDirector.create({
    required http.Client httpClient,
    List<String> poTokenConfigs = const [],
    /// Explicit bgutil HTTP endpoint. When null/empty, bgutil is NOT used
    /// (important for mobile — there is no local 127.0.0.1:4416 server).
    String? bgutilBaseUrl,
    FetchPotPolicy policy = FetchPotPolicy.auto,
  }) {
    final trimmed = bgutilBaseUrl?.trim();
    final providers = <PoTokenProvider>[
      ConfigPoTokenProvider(poTokenConfigs),
      if (trimmed != null && trimmed.isNotEmpty)
        BgUtilHttpPoTokenProvider(
          client: httpClient,
          baseUrl: trimmed,
        ),
    ];
    return PoTokenDirector(providers: providers, policy: policy);
  }

  bool get hasExternalGenerator =>
      providers.any((p) => p.name != 'config' && p.isAvailable());

  /// True only when the app actually configured a token source.
  /// Mobile apps that pass neither `poTokenConfigs` nor `bgutilBaseUrl` skip POT entirely.
  bool get isConfigured =>
      providers.whereType<ConfigPoTokenProvider>().any((p) => p.isAvailable()) ||
      hasExternalGenerator;

  Future<String?> getPoToken(
    PoTokenRequest request, {
    bool required = false,
  }) async {
    if (policy == FetchPotPolicy.never || !isConfigured) return null;
    if (policy == FetchPotPolicy.auto && !required) {
      // Still allow recommended fetches when a generator is available.
      if (!hasExternalGenerator &&
          providers.whereType<ConfigPoTokenProvider>().every((p) => !p.isAvailable())) {
        return null;
      }
    }

    if (!request.bypassCache) {
      final cached = cache.get(request);
      if (cached != null) {
        logger.debug(
          'pot',
          'Cache hit ${request.internalClientName}.${request.context.value}',
        );
        return cached;
      }
    }

    for (final provider in providers) {
      if (!provider.isAvailable()) continue;
      try {
        final response = await provider.requestPot(request);
        if (response == null) continue;
        final token = sanitizePoToken(response.poToken) ?? response.poToken;
        cache.store(request, PoTokenResponse(poToken: token, expiresAtEpochSeconds: response.expiresAtEpochSeconds));
        logger.info(
          'pot',
          'Got ${request.context.value} PO Token for '
          '${request.internalClientName} via ${provider.name}',
        );
        return token;
      } on PoTokenProviderRejected catch (e) {
        logger.debug('pot', '${provider.name} rejected: $e');
        continue;
      } on PoTokenProviderError catch (e) {
        logger.warning('pot', '${provider.name} error: $e');
        continue;
      } catch (e) {
        logger.warning('pot', '${provider.name} unexpected error: $e');
        continue;
      }
    }

    if (required) {
      logger.warning(
        'pot',
        'Required ${request.context.value} PO Token for '
        '${request.internalClientName} could not be obtained',
      );
    }
    return null;
  }
}
