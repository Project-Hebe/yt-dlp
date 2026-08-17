/// Innertube player client configs aligned with yt-dlp 2026.07.04.
library innertube_clients;

class InnertubeClient {
  final String id;
  final String clientName;
  final String clientVersion;
  final int contextClientName;
  final String userAgent;
  final Map<String, dynamic> extraClientFields;
  final bool requireJsPlayer;
  /// When true, Cookie / SAPISIDHASH may be attached (yt-dlp SUPPORTS_COOKIES).
  final bool supportsCookies;

  const InnertubeClient({
    required this.id,
    required this.clientName,
    required this.clientVersion,
    required this.contextClientName,
    required this.userAgent,
    this.extraClientFields = const {},
    this.requireJsPlayer = true,
    this.supportsCookies = false,
  });

  Map<String, dynamic> buildClientContext({
    String? visitorData,
    String hl = 'en',
  }) {
    return {
      'clientName': clientName,
      'clientVersion': clientVersion,
      'userAgent': userAgent,
      'hl': hl,
      'timeZone': 'UTC',
      'utcOffsetMinutes': 0,
      if (visitorData != null && visitorData.isNotEmpty) 'visitorData': visitorData,
      ...extraClientFields,
    };
  }

  Map<String, String> buildApiHeaders({String? visitorData}) {
    return {
      'Content-Type': 'application/json',
      'User-Agent': userAgent,
      'X-YouTube-Client-Name': '$contextClientName',
      'X-YouTube-Client-Version': clientVersion,
      'Origin': 'https://www.youtube.com',
      if (visitorData != null && visitorData.isNotEmpty) 'X-Goog-Visitor-Id': visitorData,
    };
  }
}

/// Default clients matching yt-dlp `_DEFAULT_JSLESS_CLIENTS` / `_DEFAULT_CLIENTS`.
/// Prefer jsless clients first: they return direct HTTPS URLs without player JS.
const Map<String, InnertubeClient> kInnertubeClients = {
  'android_vr': InnertubeClient(
    id: 'android_vr',
    clientName: 'ANDROID_VR',
    clientVersion: '1.65.10',
    contextClientName: 28,
    userAgent:
        'com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip',
    requireJsPlayer: false,
    extraClientFields: {
      'deviceMake': 'Oculus',
      'deviceModel': 'Quest 3',
      'androidSdkVersion': 32,
      'osName': 'Android',
      'osVersion': '12L',
    },
  ),
  'visionos': InnertubeClient(
    id: 'visionos',
    clientName: 'VISIONOS',
    clientVersion: '1.02',
    contextClientName: 101,
    userAgent:
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15',
    requireJsPlayer: false,
    extraClientFields: {
      'deviceMake': 'Apple',
      'deviceModel': 'RealityDevice17,1',
      'osName': 'visionOS',
      'osVersion': '26.5.23O471',
    },
  ),
  'web': InnertubeClient(
    id: 'web',
    clientName: 'WEB',
    clientVersion: '2.20260708.00.00',
    contextClientName: 1,
    userAgent:
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
    requireJsPlayer: true,
    supportsCookies: true,
  ),
  /// Age-gate / embed workaround (yt-dlp appends when age-restricted).
  'web_embedded': InnertubeClient(
    id: 'web_embedded',
    clientName: 'WEB_EMBEDDED_PLAYER',
    clientVersion: '2.20260708.00.00',
    contextClientName: 56,
    userAgent:
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
    requireJsPlayer: true,
    supportsCookies: true,
  ),
  'ios': InnertubeClient(
    id: 'ios',
    clientName: 'IOS',
    clientVersion: '21.26.4',
    contextClientName: 5,
    userAgent:
        'com.google.ios.youtube/21.26.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)',
    requireJsPlayer: false,
    extraClientFields: {
      'deviceMake': 'Apple',
      'deviceModel': 'iPhone16,2',
      'osName': 'iPhone',
      'osVersion': '18.3.2.22D82',
    },
  ),
  'tv': InnertubeClient(
    id: 'tv',
    clientName: 'TVHTML5',
    clientVersion: '7.20260707.07.00',
    contextClientName: 7,
    userAgent:
        'Mozilla/5.0 (ChromiumStylePlatform) Cobalt/25.lts.30.1034943-gold (unlike Gecko), Unknown_TV_Unknown_0/Unknown (Unknown, Unknown)',
    requireJsPlayer: true,
    supportsCookies: true,
  ),
  /// Kids / jsless-UNPLAYABLE workaround (yt-dlp appends when "made for kids").
  'tv_downgraded': InnertubeClient(
    id: 'tv_downgraded',
    clientName: 'TVHTML5',
    clientVersion: '5.20260707',
    contextClientName: 7,
    userAgent: 'Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version',
    requireJsPlayer: true,
    supportsCookies: true,
  ),
  'tv_simply': InnertubeClient(
    id: 'tv_simply',
    clientName: 'TVHTML5_SIMPLY',
    clientVersion: '1.0',
    contextClientName: 75,
    userAgent: 'Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version',
    requireJsPlayer: true,
    supportsCookies: true,
  ),
};

/// Mobile-first defaults: jsless clients with direct HTTPS URLs.
/// Do NOT include `web` — it needs WebPO (bgutil/proxy), which phones won't have.
const List<String> kDefaultPlayerClients = ['android_vr', 'visionos'];

/// Same as default — phones never rely on JS runtime for client selection.
const List<String> kDefaultJslessPlayerClients = ['android_vr', 'visionos'];

/// Extra jsless fallback when primary clients return nothing.
const List<String> kFallbackPlayerClients = ['ios'];

/// Logged-in cookie path (yt-dlp `_DEFAULT_AUTHED_CLIENTS`).
const List<String> kDefaultAuthedPlayerClients = ['tv_downgraded', 'web_embedded'];

/// Age-gate retry for embeddable restricted videos.
const List<String> kAgeGatePlayerClients = ['web_embedded'];

/// Made-for-kids when android_vr/visionos are UNPLAYABLE (yt-dlp append_client).
const List<String> kKidsPlayerClients = ['tv_downgraded'];

/// Last Innertube API fallback when jsless/kids/age/tv are empty.
/// Needs JS (ejs) for n/sig; may still be SABR-only without WebPO.
const List<String> kWebPlayerClients = ['web'];

/// True when watch-page HTML indicates a Made for Kids video.
bool isMadeForKidsWebpage(String html) {
  final lower = html.toLowerCase();
  return lower.contains('made for kids') ||
      lower.contains('"iskidscontent":true') ||
      lower.contains('"isMadeForKids":true'.toLowerCase());
}
