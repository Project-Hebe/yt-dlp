import 'package:test/test.dart';
import 'package:yt_dlp_dart/yt_dlp.dart';

void main() {
  test('extractInfo returns downloadable audio formats via Innertube clients', () async {
    final extractor = YouTubeExtractor(jscDirector: null);
    addTearDown(extractor.dispose);

    final info = await extractor.extractInfo('https://www.youtube.com/watch?v=jNQXAC9IVRw');

    expect(info.id, 'jNQXAC9IVRw');
    expect(info.title, isNotNull);
    expect(info.formats, isNotEmpty);

    final audioWithUrl = info.audioFormats.where((f) => f.url != null && f.url!.isNotEmpty).toList();
    expect(
      audioWithUrl,
      isNotEmpty,
      reason: 'Expected downloadable audio formats from android_vr/visionos',
    );

    // ignore: avoid_print
    print('title=${info.title}');
    // ignore: avoid_print
    print('formats=${info.formats.length} audio=${info.audioFormats.length} '
        'audioWithUrl=${audioWithUrl.length}');
    for (final f in audioWithUrl.take(5)) {
      // ignore: avoid_print
      print('  audio itag=${f.formatId} lang=${f.language} note=${f.formatNote} '
          'urlLen=${f.url?.length}');
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
