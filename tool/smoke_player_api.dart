/// Offline-network smoke for Innertube player clients (no Flutter).
///
/// Run:
///   dart run tool/smoke_player_api.dart
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:yt_dlp_dart/src/extractor/innertube_clients.dart';
import 'package:yt_dlp_dart/src/extractor/player_api.dart';

Future<void> main(List<String> args) async {
  final videoId = args.isNotEmpty ? args.first : 'jNQXAC9IVRw';
  final client = http.Client();
  try {
    final watchUrl = 'https://www.youtube.com/watch?v=$videoId';
    stdout.writeln('Fetching watch page: $watchUrl');
    final page = await client.get(
      Uri.parse(watchUrl),
      headers: {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
        'Accept-Language': 'en-US,en;q=0.9',
        'Accept-Encoding': 'identity',
        'Connection': 'close',
      },
    ).timeout(const Duration(seconds: 60));
    if (page.statusCode != 200) {
      stderr.writeln('Watch page HTTP ${page.statusCode}');
      exitCode = 2;
      return;
    }

    final html = utf8.decode(page.bodyBytes, allowMalformed: true);
    final session = extractInnertubeSession(html);
    stdout.writeln(
      'session visitor=${session.visitorData != null} apiKey=${session.apiKey != null}',
    );

    final api = PlayerApi(client);
    final clients = [...kDefaultJslessPlayerClients, ...kFallbackPlayerClients];
    final responses = await api.fetchPlayerResponses(
      videoId: videoId,
      clientIds: clients,
      visitorData: session.visitorData,
      apiKey: session.apiKey,
    );

    final merged = mergePlayerStreamingData(
      responses,
      clientPriority: clients,
      includeWebpageStreamingData: false,
    );
    final downloadable = countDownloadableFormats(merged);
    final adaptive = (merged?['adaptiveFormats'] as List?) ?? const [];
    final audio = adaptive.where((f) {
      if (f is! Map) return false;
      final mime = f['mimeType']?.toString() ?? '';
      return mime.startsWith('audio/') && isDownloadableFormat(f);
    }).toList();

    stdout.writeln('clientsOK=${responses.keys.toList()}');
    stdout.writeln(
      'downloadable=$downloadable adaptive=${adaptive.length} audioWithUrl=${audio.length}',
    );
    for (final f in audio.take(6)) {
      final m = f as Map;
      stdout.writeln(
        '  itag=${m['itag']} client=${m['_yt_dlp_client']} '
        'track=${m['audioTrack']} urlLen=${(m['url'] as String?)?.length}',
      );
    }

    if (audio.isEmpty) {
      stderr.writeln('FAIL: no downloadable audio formats');
      exitCode = 1;
      return;
    }
    stdout.writeln('PASS');
  } finally {
    client.close();
  }
}
