import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:yt_dlp_dart/src/extractor/playability.dart';
import 'package:yt_dlp_dart/src/extractor/youtube_cookies.dart';

void main() {
  group('YoutubeCookieJar', () {
    test('parses cookie header', () {
      final jar = YoutubeCookieJar.fromHeader('LOGIN_INFO=abc; SAPISID=sid123; other=1');
      expect(jar['LOGIN_INFO'], 'abc');
      expect(jar['SAPISID'], 'sid123');
      expect(jar.isAuthenticated, isTrue);
    });

    test('isAuthenticated requires LOGIN_INFO + SID', () {
      expect(
        YoutubeCookieJar.fromMap({'SAPISID': 'x'}).isAuthenticated,
        isFalse,
      );
      expect(
        YoutubeCookieJar.fromMap({
          'LOGIN_INFO': 'x',
          '__Secure-3PAPISID': 'y',
        }).isAuthenticated,
        isTrue,
      );
    });

    test('parses netscape cookie file', () {
      final netscape = [
        '# Netscape HTTP Cookie File',
        '.youtube.com\tTRUE\t/\tTRUE\t0\tLOGIN_INFO\tlogin',
        '.youtube.com\tTRUE\t/\tTRUE\t0\tSAPISID\tsid',
      ].join('\n');
      final jar = YoutubeCookieJar.fromNetscape(netscape);
      expect(jar.isAuthenticated, isTrue);
      expect(jar.toCookieHeader(), contains('LOGIN_INFO=login'));
    });

    test('SAPISIDHASH matches known digest', () {
      final auth = makeSidAuthorization(
        scheme: 'SAPISIDHASH',
        sid: 'sid',
        origin: 'https://www.youtube.com',
        timestamp: '1700000000',
      );
      final digest = sha1
          .convert(utf8.encode('1700000000 sid https://www.youtube.com'))
          .toString();
      expect(auth, 'SAPISIDHASH 1700000000_$digest');
    });

    test('buildRequestHeaders includes Cookie and Authorization when logged in', () {
      final jar = YoutubeCookieJar.fromMap({
        'LOGIN_INFO': 'x',
        'SAPISID': 'sid',
      });
      final headers = jar.buildRequestHeaders();
      expect(headers['Cookie'], contains('SAPISID=sid'));
      expect(headers['Authorization'], startsWith('SAPISIDHASH '));
      expect(headers['X-Youtube-Bootstrap-Logged-In'], 'true');
    });
  });

  group('playability', () {
    test('detects age gate from status', () {
      final info = analyzePlayability({
        'playabilityStatus': {
          'status': 'AGE_VERIFICATION_REQUIRED',
          'reason': 'Age verification required',
        },
      });
      expect(info.isAgeGated, isTrue);
      expect(info.kind, PlayabilityKind.ageRestricted);
    });

    test('detects age gate from desktopLegacyAgeGateReason', () {
      final info = analyzePlayability({
        'playabilityStatus': {
          'status': 'LOGIN_REQUIRED',
          'desktopLegacyAgeGateReason': 1,
          'reason': 'Sign in to confirm your age',
        },
      });
      expect(info.isAgeGated, isTrue);
    });

    test('detects login required', () {
      final info = analyzePlayability({
        'playabilityStatus': {
          'status': 'LOGIN_REQUIRED',
          'reason': 'Sign in to confirm you’re not a bot',
        },
      });
      expect(info.kind, PlayabilityKind.loginRequired);
    });

    test('detects geo restriction from subreason', () {
      final info = analyzePlayability({
        'playabilityStatus': {
          'status': 'UNPLAYABLE',
          'reason': 'Unavailable',
          'errorScreen': {
            'playerErrorMessageRenderer': {
              'subreason': {
                'simpleText':
                    'The uploader has not made this video available in your country',
              },
            },
          },
        },
      });
      expect(info.kind, PlayabilityKind.geoRestricted);
    });

    test('buildNoFormatsMessage mentions cookies for age gate', () {
      final msg = buildNoFormatsMessage(
        playability: const PlayabilityInfo(
          status: 'LOGIN_REQUIRED',
          reason: 'Sign in to confirm your age',
          kind: PlayabilityKind.ageRestricted,
        ),
        isAuthenticated: false,
        triedWebEmbedded: true,
      );
      expect(msg.toLowerCase(), contains('age-restricted'));
      expect(msg, contains('cookies'));
      expect(msg, contains('web_embedded'));
    });

    test('buildNoFormatsMessage for DRM', () {
      final msg = buildNoFormatsMessage(
        playability: const PlayabilityInfo(
          kind: PlayabilityKind.drmProtected,
          reason: 'This video is DRM protected',
        ),
        isAuthenticated: false,
        triedWebEmbedded: false,
      );
      expect(msg.toLowerCase(), contains('drm'));
    });

    test('streamingDataHasDrm detects licenseInfos', () {
      expect(
        streamingDataHasDrm({
          'licenseInfos': [
            {'id': 'WIDEVINE'},
          ],
        }),
        isTrue,
      );
      expect(streamingDataHasDrm({'adaptiveFormats': []}), isFalse);
    });
  });
}
