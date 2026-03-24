/// ISO 639 language code conversion utilities
/// See http://www.loc.gov/standards/iso639-2/ISO-639-2_utf-8.txt
library iso639_utils;

/// Utility class for converting between ISO 639-1 (2-letter) and ISO 639-2/T (3-letter) language codes
class ISO639Utils {
  // Language code mapping from ISO 639-1 to ISO 639-2/T
  // See http://www.loc.gov/standards/iso639-2/ISO-639-2_utf-8.txt
  static const Map<String, String> _langMap = {
    'aa': 'aar',
    'ab': 'abk',
    'ae': 'ave',
    'af': 'afr',
    'ak': 'aka',
    'am': 'amh',
    'an': 'arg',
    'ar': 'ara',
    'as': 'asm',
    'av': 'ava',
    'ay': 'aym',
    'az': 'aze',
    'ba': 'bak',
    'be': 'bel',
    'bg': 'bul',
    'bh': 'bih',
    'bi': 'bis',
    'bm': 'bam',
    'bn': 'ben',
    'bo': 'bod',
    'br': 'bre',
    'bs': 'bos',
    'ca': 'cat',
    'ce': 'che',
    'ch': 'cha',
    'co': 'cos',
    'cr': 'cre',
    'cs': 'ces',
    'cu': 'chu',
    'cv': 'chv',
    'cy': 'cym',
    'da': 'dan',
    'de': 'deu',
    'dv': 'div',
    'dz': 'dzo',
    'ee': 'ewe',
    'el': 'ell',
    'en': 'eng',
    'eo': 'epo',
    'es': 'spa',
    'et': 'est',
    'eu': 'eus',
    'fa': 'fas',
    'ff': 'ful',
    'fi': 'fin',
    'fj': 'fij',
    'fo': 'fao',
    'fr': 'fra',
    'fy': 'fry',
    'ga': 'gle',
    'gd': 'gla',
    'gl': 'glg',
    'gn': 'grn',
    'gu': 'guj',
    'gv': 'glv',
    'ha': 'hau',
    'he': 'heb',
    'iw': 'heb', // Replaced by he in 1989 revision
    'hi': 'hin',
    'ho': 'hmo',
    'hr': 'hrv',
    'ht': 'hat',
    'hu': 'hun',
    'hy': 'hye',
    'hz': 'her',
    'ia': 'ina',
    'id': 'ind',
    'in': 'ind', // Replaced by id in 1989 revision
    'ie': 'ile',
    'ig': 'ibo',
    'ii': 'iii',
    'ik': 'ipk',
    'io': 'ido',
    'is': 'isl',
    'it': 'ita',
    'iu': 'iku',
    'ja': 'jpn',
    'jv': 'jav',
    'ka': 'kat',
    'kg': 'kon',
    'ki': 'kik',
    'kj': 'kua',
    'kk': 'kaz',
    'kl': 'kal',
    'km': 'khm',
    'kn': 'kan',
    'ko': 'kor',
    'kr': 'kau',
    'ks': 'kas',
    'ku': 'kur',
    'kv': 'kom',
    'kw': 'cor',
    'ky': 'kir',
    'la': 'lat',
    'lb': 'ltz',
    'lg': 'lug',
    'li': 'lim',
    'ln': 'lin',
    'lo': 'lao',
    'lt': 'lit',
    'lu': 'lub',
    'lv': 'lav',
    'mg': 'mlg',
    'mh': 'mah',
    'mi': 'mri',
    'mk': 'mkd',
    'ml': 'mal',
    'mn': 'mon',
    'mr': 'mar',
    'ms': 'msa',
    'mt': 'mlt',
    'my': 'mya',
    'na': 'nau',
    'nb': 'nob',
    'nd': 'nde',
    'ne': 'nep',
    'ng': 'ndo',
    'nl': 'nld',
    'nn': 'nno',
    'no': 'nor',
    'nr': 'nbl',
    'nv': 'nav',
    'ny': 'nya',
    'oc': 'oci',
    'oj': 'oji',
    'om': 'orm',
    'or': 'ori',
    'os': 'oss',
    'pa': 'pan',
    'pe': 'per',
    'pi': 'pli',
    'pl': 'pol',
    'ps': 'pus',
    'pt': 'por',
    'qu': 'que',
    'rm': 'roh',
    'rn': 'run',
    'ro': 'ron',
    'ru': 'rus',
    'rw': 'kin',
    'sa': 'san',
    'sc': 'srd',
    'sd': 'snd',
    'se': 'sme',
    'sg': 'sag',
    'si': 'sin',
    'sk': 'slk',
    'sl': 'slv',
    'sm': 'smo',
    'sn': 'sna',
    'so': 'som',
    'sq': 'sqi',
    'sr': 'srp',
    'ss': 'ssw',
    'st': 'sot',
    'su': 'sun',
    'sv': 'swe',
    'sw': 'swa',
    'ta': 'tam',
    'te': 'tel',
    'tg': 'tgk',
    'th': 'tha',
    'ti': 'tir',
    'tk': 'tuk',
    'tl': 'tgl',
    'tn': 'tsn',
    'to': 'ton',
    'tr': 'tur',
    'ts': 'tso',
    'tt': 'tat',
    'tw': 'twi',
    'ty': 'tah',
    'ug': 'uig',
    'uk': 'ukr',
    'ur': 'urd',
    'uz': 'uzb',
    've': 'ven',
    'vi': 'vie',
    'vo': 'vol',
    'wa': 'wln',
    'wo': 'wol',
    'xh': 'xho',
    'yi': 'yid',
    'ji': 'yid', // Replaced by yi in 1989 revision
    'yo': 'yor',
    'za': 'zha',
    'zh': 'zho',
    'zu': 'zul',
  };

  /// Convert language code from ISO 639-1 (2-letter) to ISO 639-2/T (3-letter)
  /// 
  /// Example:
  /// ```dart
  /// ISO639Utils.short2long('en') // Returns 'eng'
  /// ISO639Utils.short2long('zh') // Returns 'zho'
  /// ISO639Utils.short2long('invalid') // Returns null
  /// ```
  /// 
  /// [code] - ISO 639-1 language code (2 letters)
  /// Returns ISO 639-2/T language code (3 letters) or null if not found
  static String? short2long(String? code) {
    if (code == null || code.isEmpty) {
      return null;
    }
    // Take first 2 characters (matching Python: code[:2])
    final shortCode = code.length >= 2 ? code.substring(0, 2).toLowerCase() : code.toLowerCase();
    return _langMap[shortCode];
  }

  /// Convert language code from ISO 639-2/T (3-letter) to ISO 639-1 (2-letter)
  /// 
  /// Example:
  /// ```dart
  /// ISO639Utils.long2short('eng') // Returns 'en'
  /// ISO639Utils.long2short('zho') // Returns 'zh'
  /// ISO639Utils.long2short('invalid') // Returns null
  /// ```
  /// 
  /// [code] - ISO 639-2/T language code (3 letters)
  /// Returns ISO 639-1 language code (2 letters) or null if not found
  static String? long2short(String? code) {
    if (code == null || code.isEmpty) {
      return null;
    }
    final longCode = code.toLowerCase();
    // Search for the matching long code in the map
    for (final entry in _langMap.entries) {
      if (entry.value == longCode) {
        return entry.key;
      }
    }
    return null;
  }

  /// Check if a language code is valid (either ISO 639-1 or ISO 639-2/T)
  /// 
  /// Example:
  /// ```dart
  /// ISO639Utils.isValid('en') // Returns true
  /// ISO639Utils.isValid('eng') // Returns true
  /// ISO639Utils.isValid('invalid') // Returns false
  /// ```
  static bool isValid(String? code) {
    if (code == null || code.isEmpty) {
      return false;
    }
    final normalized = code.toLowerCase();
    if (normalized.length == 2) {
      return _langMap.containsKey(normalized);
    } else if (normalized.length == 3) {
      return _langMap.containsValue(normalized);
    }
    return false;
  }

  /// Normalize a language code to ISO 639-1 format (2-letter)
  /// If the code is already in ISO 639-1 format, returns it as-is
  /// If the code is in ISO 639-2/T format, converts it to ISO 639-1
  /// Otherwise returns null
  /// 
  /// Example:
  /// ```dart
  /// ISO639Utils.normalizeToShort('en') // Returns 'en'
  /// ISO639Utils.normalizeToShort('eng') // Returns 'en'
  /// ISO639Utils.normalizeToShort('invalid') // Returns null
  /// ```
  static String? normalizeToShort(String? code) {
    if (code == null || code.isEmpty) {
      return null;
    }
    final normalized = code.toLowerCase();
    if (normalized.length == 2) {
      return _langMap.containsKey(normalized) ? normalized : null;
    } else if (normalized.length == 3) {
      return long2short(normalized);
    }
    return null;
  }

  /// Normalize a language code to ISO 639-2/T format (3-letter)
  /// If the code is already in ISO 639-2/T format, returns it as-is
  /// If the code is in ISO 639-1 format, converts it to ISO 639-2/T
  /// Otherwise returns null
  /// 
  /// Example:
  /// ```dart
  /// ISO639Utils.normalizeToLong('en') // Returns 'eng'
  /// ISO639Utils.normalizeToLong('eng') // Returns 'eng'
  /// ISO639Utils.normalizeToLong('invalid') // Returns null
  /// ```
  static String? normalizeToLong(String? code) {
    if (code == null || code.isEmpty) {
      return null;
    }
    final normalized = code.toLowerCase();
    if (normalized.length == 2) {
      return short2long(normalized);
    } else if (normalized.length == 3) {
      return _langMap.containsValue(normalized) ? normalized : null;
    }
    return null;
  }
}

