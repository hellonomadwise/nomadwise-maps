import 'currencies.dart';
import 'phone_field.dart';

/// Prices in the local currency, written the way travellers expect:
/// euro, pound and dollar with the symbol in front ("€3.60"), every
/// other currency with its code after the amount ("40k IDR",
/// "900 LKR"). Owners type only the amount; the currency comes from
/// the space's country and can be changed (some places price in USD).
class Price {
  static const _symbols = {'EUR': '€', 'GBP': '£', 'USD': '\$'};

  /// The currency a country uses today, or null when unknown.
  static String? forCountry(String? countryName) {
    final iso = PhoneField.isoFor(countryName);
    return iso == null ? null : countryCurrency[iso];
  }

  static String name(String code) => currencyNames[code] ?? code;

  /// The currency written in a stored price, if any.
  static String? codeIn(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return null;
    for (final e in _symbols.entries) {
      if (t.contains(e.value)) return e.key;
    }
    for (final m in RegExp(r'[A-Za-z]{3}').allMatches(t)) {
      final c = m.group(0)!.toUpperCase();
      if (currencyNames.containsKey(c)) return c;
    }
    return null;
  }

  /// Just the amount of a stored price ("€3.60" → "3.60").
  static String amountOf(String raw) {
    var t = raw.trim();
    for (final s in _symbols.values) {
      t = t.replaceAll(s, '');
    }
    final code = codeIn(raw);
    if (code != null) {
      t = t.replaceAll(RegExp(code, caseSensitive: false), '');
    }
    return t.trim();
  }

  /// The amount written for the page, or '' when there is none.
  static String format(String amount, String code) {
    final a = amount.trim();
    if (a.isEmpty) return '';
    final sym = _symbols[code];
    return sym != null ? '$sym$a' : '$a $code';
  }

  static String? prefixFor(String code) => _symbols[code];
  static String? suffixFor(String code) =>
      _symbols.containsKey(code) ? null : code;
}
