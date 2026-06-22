/// Indian number plate validation & OCR confusion correction.
///
/// Ported from the Python plate_reader.py — exact same logic.

// ── Valid state codes ──────────────────────────────────────────────────────

const _validStateCodes = {
  'AN', 'AP', 'AR', 'AS', 'BR', 'CH', 'CG', 'CT', 'DD', 'DL', 'DN', 'GA',
  'GJ', 'HR', 'HP', 'JH', 'JK', 'KA', 'KL', 'LA', 'LD', 'MH', 'ML', 'MN',
  'MP', 'MZ', 'NL', 'OD', 'OR', 'PB', 'PY', 'RJ', 'SK', 'TN', 'TR', 'TS',
  'UA', 'UK', 'UP', 'WB',
};

// ── Confusion maps ─────────────────────────────────────────────────────────

const _digitFix = {
  'O': '0', 'Q': '0', 'I': '1', 'Z': '2', 'S': '5', 'B': '8',
};

const _letterSubs = {
  '0': ['Q'], '5': ['S'], '8': ['B'],
};

const _letterConfusion = {
  'V': ['Y'], 'Y': ['V'], 'U': ['V'], 'M': ['N'], 'N': ['M'],
};

// ── Regex patterns for valid plates ───────────────────────────────────────

final _bhPattern = RegExp(r'^\d{2}BH\d{4}[A-Z]{1,2}$');
final _std1Pattern = RegExp(r'^[A-Z]{2}\d{2}[A-HJ-NP-Z]\d{4}$');
final _std2Pattern = RegExp(r'^[A-Z]{2}\d{2}[A-HJ-NP-Z]{2}\d{4}$');

// ── Public API ─────────────────────────────────────────────────────────────

/// Clean raw OCR text: upper-case, strip separators.
String baseclean(String text) =>
    text.toUpperCase().replaceAll(RegExp(r'[\s\-.,_()\|]'), '');

/// Validate a plate string against Indian formats.
bool validatePlate(String text) {
  if (_bhPattern.hasMatch(text)) return true;
  if (_std1Pattern.hasMatch(text) && _validStateCodes.contains(text.substring(0, 2))) {
    return true;
  }
  if (_std2Pattern.hasMatch(text) && _validStateCodes.contains(text.substring(0, 2))) {
    return true;
  }
  return false;
}

/// Generate all confusion-corrected candidate strings from [text].
///
/// Applies:
/// - Standard digit↔letter confusion fixes
/// - Letter look-alike substitutions (V↔Y, M↔N, etc.)
/// - BH-series position-aware pass
/// - Substring sliding window for partial reads
List<String> generateCandidates(String text) {
  final n = text.length;
  final seen = <String>{};
  final result = <String>[];

  void add(List<String> chars) {
    final s = chars.join();
    if (seen.add(s)) result.add(s);
  }

  final chars = text.split('');
  add(chars);

  // Position sets for standard plate
  final digitIdx = [2, 3, ...List.generate(4, (i) => n - 4 + i).where((i) => i >= 0)];
  final letterIdx = [0, 1, ...List.generate(n - 8, (i) => i + 4).where((i) => i >= 4 && i < n - 4)];

  // ── Standard pass ───────────────────────────────────────────────────
  final std = List<String>.from(chars);
  for (final i in digitIdx) {
    if (i < n && _digitFix.containsKey(std[i])) std[i] = _digitFix[std[i]]!;
  }
  for (final i in letterIdx) {
    if (i < n && _letterSubs.containsKey(std[i])) std[i] = _letterSubs[std[i]]![0];
  }
  add(std);

  // ── Letter confusion pass ───────────────────────────────────────────
  final allLetterIdx = [...List.generate(2, (i) => i), ...List.generate(n - 8, (i) => i + 4).where((i) => i >= 4)];
  for (final ti in allLetterIdx) {
    if (ti >= n) continue;
    final confused = _letterConfusion[std[ti]] ?? [];
    for (final alt in confused) {
      final variant = List<String>.from(std);
      variant[ti] = alt;
      add(variant);
    }
  }

  // ── BH-series pass ─────────────────────────────────────────────────
  final bh = List<String>.from(chars);
  final bhDi = [0, 1, ...List.generate(4, (i) => i + 4).where((i) => i < n)];
  final bhLi = [2, 3, ...List.generate(n - 8, (i) => i + 8).where((i) => i < n)];
  for (final i in bhDi) {
    if (i < n && _digitFix.containsKey(bh[i])) bh[i] = _digitFix[bh[i]]!;
  }
  for (final i in bhLi) {
    if (i < n && _letterSubs.containsKey(bh[i])) bh[i] = _letterSubs[bh[i]]![0];
  }
  add(bh);

  // ── Substring sliding window ────────────────────────────────────────
  for (int length = (n < 11 ? n : 11); length >= 9; length--) {
    for (int start = 0; start <= n - length; start++) {
      final sub = text.substring(start, start + length).split('');
      add(sub);
      // Apply standard fix to substring
      final sn = sub.length;
      final sf = List<String>.from(sub);
      final sDi = [2, 3, ...List.generate(4, (i) => sn - 4 + i).where((i) => i >= 0)];
      final sLi = [0, 1, ...List.generate(sn - 8, (i) => i + 4).where((i) => i >= 4 && i < sn - 4)];
      for (final i in sDi) {
        if (i < sn && _digitFix.containsKey(sf[i])) sf[i] = _digitFix[sf[i]]!;
      }
      for (final i in sLi) {
        if (i < sn && _letterSubs.containsKey(sf[i])) sf[i] = _letterSubs[sf[i]]![0];
      }
      add(sf);
    }
  }

  return result;
}

/// From a list of (plateText, confidence) hits, elect the most-frequent plate.
/// Ties broken by highest confidence.
String? electBestPlate(List<(String, double)> hits) {
  if (hits.isEmpty) return null;
  final freq = <String, int>{};
  final bestConf = <String, double>{};
  for (final (plate, conf) in hits) {
    freq[plate] = (freq[plate] ?? 0) + 1;
    if (conf > (bestConf[plate] ?? 0.0)) bestConf[plate] = conf;
  }
  return freq.entries
      .reduce((a, b) {
        if (a.value != b.value) return a.value > b.value ? a : b;
        return (bestConf[a.key] ?? 0) >= (bestConf[b.key] ?? 0) ? a : b;
      })
      .key;
}
