/// Price check: things worth checking in a space's prices before they
/// go on its page (Jonathan, 9 Nov 2026, on Westerwelle Arusha's
/// prices: "how when looking at these prices do i identify this, work
/// it out ... I'd like to automate or make easier a way to check that
/// the prices could be overlapped or incorrect, and then ... go back
/// to the owner with a request to check").
///
/// Reads each product's name, price words and details, and works out
/// what a visitor gets: for how long (an hour, a day, a week, a month,
/// a year) and what space (any free desk, their own desk, a private
/// office, a meeting room). Then it looks for:
///   - two products that sell the same thing (same space, same length)
///   - a price that does not say per what (day, week or month)
///   - "Price on request" next to a priced product of the same kind
///   - a longer stay that costs less than a shorter one, or more than
///     paying by the day
///   - more than one currency
///   - a price that is unusual once in euros (a zero too many or few)
///   - the same name twice
/// These are guesses, worded as questions: each says what to look at,
/// and how to ask the owner.
library;

class PriceIssue {
  /// What to look at, for us.
  final String see;

  /// The same as a question for the owner.
  final String ask;
  const PriceIssue(this.see, this.ask);
}

/// One product as it will be on the page.
class _P {
  final String name;
  final String label;
  final num? amount;
  final String currency;
  final String kind; // shared, fixed, office, meeting, other
  final String? period; // hour, day, week, month, year
  const _P(this.name, this.label, this.amount, this.currency, this.kind, this.period);
}

String _words(Map<String, dynamic> p) {
  final details = p['details'] is List ? (p['details'] as List).join(' ') : '';
  return ' ${p['name'] ?? ''} ${p['label'] ?? ''} $details '.toLowerCase();
}

bool _has(String s, List<String> words) =>
    words.any((w) => RegExp('(^|[^a-z])${RegExp.escape(w)}([^a-z]|\$)').hasMatch(s));

String? _periodOf(Map<String, dynamic> p) {
  final s = _words(p);
  // a pack of days ("10 day pass", "5-day bundle") is not a day price
  if (RegExp(r'\b([2-9]|[1-9][0-9])[ -]?(day|days|visit|visits|entries)\b').hasMatch(s)) {
    return 'pack';
  }
  if (_has(s, ['year', 'yearly', 'annual', 'annually', 'per year', '/yr'])) return 'year';
  if (_has(s, ['month', 'monthly', 'months', '/mo', '/month', 'mes', 'mensal', 'mensual', 'monat', 'mois'])) {
    return 'month';
  }
  if (_has(s, ['week', 'weekly', 'weeks', '/wk', 'semana', 'woche', 'semaine'])) return 'week';
  if (_has(s, ['day', 'daily', 'days', '/day', 'dia', 'día', 'tag', 'jour', 'half day', 'half-day'])) {
    return 'day';
  }
  if (_has(s, ['hour', 'hourly', 'hours', '/hr', '/h', 'hora', 'stunde', 'heure'])) return 'hour';
  return null;
}

String _kindOf(Map<String, dynamic> p) {
  final s = _words(p);
  final cat = '${p['category'] ?? ''}';
  if (cat == 'meeting_room' || _has(s, ['meeting', 'conference', 'boardroom', 'event', 'events'])) {
    return 'meeting';
  }
  if (cat == 'private_office' || _has(s, ['office', 'offices', 'suite', 'studio'])) return 'office';
  if (_has(s, ['dedicated', 'fixed', 'resident', 'permanent', 'own desk', 'assigned'])) return 'fixed';
  if (cat == 'coworking' ||
      _has(s, ['hot desk', 'hot-desk', 'hotdesk', 'flex', 'flexible', 'pass', 'coworking', 'co-working', 'desk', 'membership'])) {
    return 'shared';
  }
  return 'other';
}

const _kindWords = {
  'shared': 'a shared desk',
  'fixed': 'their own desk',
  'office': 'a private office',
  'meeting': 'a meeting room',
};

const _periodWords = {
  'hour': 'an hour',
  'day': 'a day',
  'week': 'a week',
  'month': 'a month',
  'year': 'a year',
};

const _periodDays = {'day': 1.0, 'week': 7.0, 'month': 30.0, 'year': 365.0};

/// Rough bounds in euros that a price of this kind and length rarely
/// falls outside. Only used to spot a zero too many or too few.
const _bounds = <String, (double, double)>{
  'shared/day': (1.0, 90.0),
  'shared/week': (5.0, 400.0),
  'shared/month': (15.0, 1500.0),
  'fixed/month': (20.0, 2500.0),
  'office/month': (40.0, 20000.0),
  'meeting/hour': (2.0, 400.0),
};

String _money(num v, String code) {
  final whole = v == v.roundToDouble();
  final s = whole ? v.toInt().toString() : v.toStringAsFixed(2);
  final grouped = s.replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
  return code.isEmpty ? grouped : '$grouped $code';
}

String _q(String name) => '"$name"';

/// Things worth checking in [items], the products as they will be on
/// the page. [toEur] turns an amount in a currency into euros, or null
/// when the rate is not known.
List<PriceIssue> priceIssues(List<Map<String, dynamic>> items,
    {double? Function(num amount, String currency)? toEur}) {
  final ps = [
    for (final p in items)
      _P(
        '${p['name'] ?? ''}'.trim().isEmpty ? 'A product' : '${p['name']}'.trim(),
        '${p['label'] ?? ''}'.trim(),
        p['amount'] is num ? p['amount'] as num : null,
        '${p['currency'] ?? ''}'.trim().toUpperCase(),
        _kindOf(p),
        _periodOf(p),
      )
  ];
  final out = <PriceIssue>[];
  final asked = <String>{};
  void add(String key, String see, String ask) {
    if (asked.add(key)) out.add(PriceIssue(see, ask));
  }

  // The same name twice.
  final byName = <String, List<_P>>{};
  for (final p in ps) {
    byName.putIfAbsent(p.name.toLowerCase(), () => []).add(p);
  }
  for (final l in byName.values.where((l) => l.length > 1)) {
    add('name:${l.first.name}', '${_q(l.first.name)} is there ${l.length} times.',
        'We have ${_q(l.first.name)} ${l.length} times. Should it be once, or are they different (for example a day and a month)?');
  }

  final kinds = {'shared', 'fixed', 'office', 'meeting'};

  // Two products that sell the same thing.
  for (var i = 0; i < ps.length; i++) {
    for (var j = i + 1; j < ps.length; j++) {
      final a = ps[i], b = ps[j];
      if (a.name.toLowerCase() == b.name.toLowerCase()) continue;
      if (!kinds.contains(a.kind) || a.kind != b.kind) continue;
      if (a.period != null && a.period == b.period && a.period != 'pack') {
        add('same:${a.name}|${b.name}',
            '${_q(a.name)} and ${_q(b.name)} both look like ${_periodWords[a.period]} at ${_kindWords[a.kind]}. Are they the same thing?',
            '${_q(a.name)} and ${_q(b.name)} look like the same thing (${_periodWords[a.period]} at ${_kindWords[a.kind]}). Are they different? If they are the same, we will show just one.');
      }
    }
  }

  // A price that does not say per what.
  for (final p in ps) {
    if (!kinds.contains(p.kind) || p.period != null || p.amount == null) continue;
    final monthly = ps.where((x) =>
        x != p && x.kind == p.kind && x.period == 'month' && x.name.toLowerCase() != p.name.toLowerCase());
    if (monthly.isNotEmpty) {
      final m = monthly.first;
      add('per:${p.name}',
          '${_q(p.name)} (${p.label.isEmpty ? _money(p.amount!, p.currency) : p.label}) does not say per day, week or month. If it is per month, it may be the same as ${_q(m.name)}.',
          'Is ${_q(p.name)} (${p.label.isEmpty ? _money(p.amount!, p.currency) : p.label}) per day, per week or per month? If it is per month, is it the same as ${_q(m.name)}?');
    } else {
      add('per:${p.name}',
          '${_q(p.name)} (${p.label.isEmpty ? _money(p.amount!, p.currency) : p.label}) does not say per day, week or month.',
          'Is ${_q(p.name)} (${p.label.isEmpty ? _money(p.amount!, p.currency) : p.label}) per day, per week or per month?');
    }
  }

  // "Price on request" next to a priced product of the same kind.
  for (final p in ps) {
    if (p.amount != null || !kinds.contains(p.kind)) continue;
    final priced = ps.where((x) => x.kind == p.kind && x.amount != null && x != p).toList();
    if (priced.isEmpty) continue;
    // the likeliest twin: the same length, else one that does not say
    priced.sort((a, b) => (a.period == p.period ? 0 : a.period == null ? 1 : 2)
        .compareTo(b.period == p.period ? 0 : b.period == null ? 1 : 2));
    add('ask:${p.name}',
        '${_q(p.name)} shows "Price on request" while other ${_kindWords[p.kind]} prices are shown. Is there a price, or is it the same as one of them?',
        '${_q(p.name)} shows "Price on request". Could you give us the price, or tell us if it is the same as ${_q(priced.first.name)}?');
  }

  // A longer stay that costs less than a shorter one, or more than
  // paying by the day. Compared in one currency.
  for (final k in kinds) {
    final dated = ps.where((p) =>
        p.kind == k && p.amount != null && _periodDays.containsKey(p.period)).toList()
      ..sort((a, b) => _periodDays[a.period]!.compareTo(_periodDays[b.period]!));
    for (var i = 0; i < dated.length; i++) {
      for (var j = i + 1; j < dated.length; j++) {
        final s = dated[i], l = dated[j];
        if (s.period == l.period || s.currency != l.currency) continue;
        if (l.amount! < s.amount!) {
          add('order:${s.name}|${l.name}',
              '${_q(l.name)} (${_periodWords[l.period]}) costs less than ${_q(s.name)} (${_periodWords[s.period]}).',
              '${_q(l.name)} costs less than ${_q(s.name)}. Is that right, or has one of them a zero too many or too few?');
        } else if (s.period == 'day' &&
            l.amount! > s.amount! * _periodDays[l.period]! * 1.05) {
          add('order:${s.name}|${l.name}',
              '${_q(l.name)} costs more than paying ${_q(s.name)} every day for ${_periodWords[l.period]}.',
              '${_q(l.name)} costs more than buying ${_q(s.name)} every day. Is that right?');
        }
      }
    }
  }

  // More than one currency.
  final codes = {for (final p in ps) if (p.amount != null && p.currency.isNotEmpty) p.currency};
  if (codes.length > 1) {
    add('cur', 'The prices use ${codes.length} currencies (${codes.join(', ')}).',
        'Your prices are in ${codes.join(' and ')}. Which currency should we show them in?');
  }

  // Unusual once in euros.
  if (toEur != null) {
    for (final p in ps) {
      if (p.amount == null || p.period == null || p.currency.isEmpty) continue;
      final b = _bounds['${p.kind}/${p.period}'];
      if (b == null) continue;
      final e = toEur(p.amount!, p.currency);
      if (e == null || (e >= b.$1 && e <= b.$2)) continue;
      final eur = e < 10 ? e.toStringAsFixed(2) : e.round().toString();
      add('eur:${p.name}',
          '${_q(p.name)} is about €$eur for ${_periodWords[p.period]}, which is unusual. Check for a zero too many or too few.',
          'Could you check the price of ${_q(p.name)} (${p.label.isEmpty ? _money(p.amount!, p.currency) : p.label})?');
    }
  }
  return out;
}

/// The message to the owner: one question per thing to check.
String priceCheckMessage(String spaceName, List<PriceIssue> issues) {
  final team = spaceName.trim().isEmpty ? 'Hi,' : 'Hi ${spaceName.trim()} team,';
  return [
    team,
    '',
    'Thank you for adding your prices. Before they go on your page, could you check a few things for us?',
    '',
    for (final i in issues) '- ${i.ask}',
    '',
    'Just reply here, or change them in your Owner account. Thank you!',
  ].join('\n');
}
