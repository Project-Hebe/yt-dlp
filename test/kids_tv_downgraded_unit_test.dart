import 'package:test/test.dart';
import 'package:yt_dlp_dart/src/extractor/innertube_clients.dart';

void main() {
  group('made for kids', () {
    test('detects made for kids phrase', () {
      expect(isMadeForKidsWebpage('<html>This video is made for kids</html>'), isTrue);
      expect(isMadeForKidsWebpage('<html>normal video</html>'), isFalse);
    });

    test('detects isKidsContent / isMadeForKids flags', () {
      expect(isMadeForKidsWebpage('{"isKidsContent":true}'), isTrue);
      expect(isMadeForKidsWebpage('{"isMadeForKids":true}'), isTrue);
    });

    test('tv_downgraded client is registered', () {
      final c = kInnertubeClients['tv_downgraded'];
      expect(c, isNotNull);
      expect(c!.clientName, 'TVHTML5');
      expect(c.clientVersion, '5.20260707');
      expect(kKidsPlayerClients, contains('tv_downgraded'));
    });

    test('web player fallback client is registered', () {
      expect(kWebPlayerClients, ['web']);
      expect(kInnertubeClients['web']?.clientName, 'WEB');
    });
  });
}
