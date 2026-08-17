import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:yt_dlp_dart/src/extractor/pot/bgutil_http_provider.dart';
import 'package:yt_dlp_dart/src/extractor/pot/cache.dart';
import 'package:yt_dlp_dart/src/extractor/pot/config_provider.dart';
import 'package:yt_dlp_dart/src/extractor/pot/director.dart';
import 'package:yt_dlp_dart/src/extractor/pot/models.dart';
import 'package:yt_dlp_dart/src/extractor/pot/utils.dart';
import 'package:yt_dlp_dart/src/extractor/player_api.dart';

class _FakeClient extends http.BaseClient {
  final Map<String, http.Response> routes;
  _FakeClient(this.routes);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final key = '${request.method} ${request.url.path}';
    final resp = routes[key] ?? http.Response('not found', 404);
    return http.StreamedResponse(
      Stream.value(resp.bodyBytes),
      resp.statusCode,
      headers: resp.headers,
    );
  }
}

void main() {
  group('pot utils', () {
    test('parses CLIENT.CONTEXT+TOKEN', () {
      final raw = base64Url.encode(utf8.encode('hello-pot'));
      final tokens = parsePoTokenConfigs([
        'android_vr.gvs+$raw',
        'web.player+$raw',
      ]);
      expect(
        lookupConfiguredPoToken(tokens, client: 'web', context: PoTokenContext.player),
        isNotNull,
      );
    });

    test('web content binding uses visitorData for GVS', () {
      final binding = getWebPoContentBinding(
        PoTokenRequest(
          context: PoTokenContext.gvs,
          internalClientName: 'web',
          visitorData: 'VISITOR',
          innertubeContext: {
            'client': {'clientName': 'WEB'},
          },
        ),
      );
      expect(binding.binding, 'VISITOR');
      expect(binding.type, ContentBindingType.visitorData);
    });
  });

  group('pot director', () {
    test('uses config provider first', () async {
      final raw = base64Url.encode(utf8.encode('cfg-token'));
      final director = PoTokenDirector(
        providers: [ConfigPoTokenProvider(['web.gvs+$raw'])],
        policy: FetchPotPolicy.always,
      );
      final token = await director.getPoToken(
        PoTokenRequest(
          context: PoTokenContext.gvs,
          internalClientName: 'web',
          visitorData: 'v',
          innertubeContext: {
            'client': {'clientName': 'WEB'},
          },
        ),
        required: true,
      );
      expect(token, isNotNull);
    });

    test('bgutil http provider parses poToken response', () async {
      final client = _FakeClient({
        'GET /ping': http.Response(json.encode({'version': '1.3.1'}), 200),
        'POST /get_pot': http.Response(
          json.encode({'poToken': base64Url.encode(utf8.encode('generated'))}),
          200,
          headers: {'content-type': 'application/json'},
        ),
      });
      final provider = BgUtilHttpPoTokenProvider(client: client);
      final resp = await provider.requestPot(
        PoTokenRequest(
          context: PoTokenContext.gvs,
          internalClientName: 'web',
          visitorData: 'visitor-data',
          videoId: 'abcd',
          innertubeContext: {
            'client': {'clientName': 'WEB', 'visitorData': 'visitor-data'},
          },
        ),
      );
      expect(resp?.poToken, isNotNull);
    });

    test('memory cache roundtrip', () {
      final cache = PoTokenMemoryCache(defaultTtlSeconds: 60);
      final req = PoTokenRequest(
        context: PoTokenContext.gvs,
        internalClientName: 'web',
        visitorData: 'visitor',
        innertubeContext: {
          'client': {'clientName': 'WEB'},
        },
      );
      expect(cache.get(req), isNull);
      cache.store(req, PoTokenResponse(poToken: 'cached-token'));
      expect(cache.get(req), 'cached-token');
    });
  });

  group('mergePlayerStreamingData', () {
    test('ignores webpage SABR stubs by default', () {
      final merged = mergePlayerStreamingData(
        {},
        webpageStreamingData: {
          'adaptiveFormats': [
            {'itag': 140, 'mimeType': 'audio/mp4'},
          ],
        },
      );
      expect(merged, isNull);
    });

    test('mergePlayerStreamingData can absorb webpage when enabled', () {
      final merged = mergePlayerStreamingData(
        {},
        webpageStreamingData: {
          'adaptiveFormats': [
            {
              'itag': 140,
              'mimeType': 'audio/mp4',
              'url': 'https://googlevideo.com/videoplayback?id=1',
            },
          ],
        },
        includeWebpageStreamingData: true,
      );
      expect(merged, isNotNull);
      expect((merged!['adaptiveFormats'] as List).length, 1);
    });
  });
}
