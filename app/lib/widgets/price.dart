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

  /// One way of writing an amount, whatever the owner typed: thousands
  /// with a comma, decimals with a dot ("1.000" and "1,000" become
  /// "1,000"; "3,6" and "3.60" become "3.60"; "40k" stays "40k"). A
  /// separator followed by one or two digits is the decimal point; by
  /// three, it groups thousands (Leonie, S3-7).
  static String cleanAmount(String raw) {
    var t = raw.trim().replaceAll(' ', '');
    if (t.isEmpty) return '';
    final k = RegExp(r'^(\d+(?:[.,]\d+)?)[kK]$').firstMatch(t);
    if (k != null) return '${k.group(1)!.replaceAll(',', '.')}k';
    t = t.replaceAll(RegExp(r'[^0-9.,]'), '');
    if (!RegExp(r'\d').hasMatch(t)) return '';
    var whole = t;
    var dec = '';
    final last = t.lastIndexOf(RegExp(r'[.,]'));
    if (last >= 0) {
      final after = t.substring(last + 1);
      if (RegExp(r'^\d{1,2}$').hasMatch(after)) {
        dec = after;
        whole = t.substring(0, last);
      }
    }
    whole = whole.replaceAll(RegExp(r'[.,]'), '');
    if (whole.isEmpty) whole = '0';
    whole = whole.replaceFirst(RegExp(r'^0+(?=\d)'), '');
    final out = StringBuffer();
    for (var i = 0; i < whole.length; i++) {
      if (i > 0 && (whole.length - i) % 3 == 0) out.write(',');
      out.write(whole[i]);
    }
    if (dec.length == 1) dec = '${dec}0';
    return dec.isEmpty ? '$out' : '$out.$dec';
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
