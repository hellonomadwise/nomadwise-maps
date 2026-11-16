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
  /// Which check and which products: the same point keeps the same
  /// key, so once the owner was asked about it, it is not asked again.
  final String key;

  /// What to look at, for us.
  final String see;

  /// The same as a question for the owner.
  final String ask;
  const PriceIssue(this.key, this.see, this.ask);
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

/// A pack of days in a name ("10 day pass", "100 Day Pass", "5-day
/// bundle"): that many day passes bought at once, not a day's price
/// (Jonathan, 16 Nov 2026, on Avila Spaces: "10 day pass means 10 x
/// day passes. So a bulk amount of passes"). Any number from 2 up; it
/// used to stop at 99, so "100 Day Pass" was read as one dear day.
final _packRe = RegExp(r'\b([2-9]|[1-9][0-9]+)[ -]?(day|days|visit|visits|entries)\b');

/// How many passes a pack holds, from its name; null when not a pack.
int? _packCount(String name) {
  final m = _packRe.firstMatch(name.toLowerCase());
  return m == null ? null : int.tryParse(m.group(1)!);
}

/// For how long: what the owner chose ("Per month") first, then what
/// the name says, and only then the details. The details used to count
/// as much as the name, so "24 hour access" or "8 hours meeting room
/// per month" in a list of what is included could decide it.
String? _periodOf(Map<String, dynamic> p) {
  final details = [
    for (final d in (p['details'] is List ? p['details'] as List : const [])) '$d'
  ];
  return perOf(details) ??
      _periodIn(' ${p['name'] ?? ''} '.toLowerCase()) ??
      _periodIn(_words(p));
}

String? _periodIn(String s) {
  if (_packRe.hasMatch(s)) return 'pack';
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

const _fixedWords = ['dedicated', 'fixed', 'resident', 'permanent', 'own desk', 'assigned'];

/// The space a text speaks of, or null when it does not say.
String? _kindIn(String s) {
  if (_has(s, ['meeting', 'conference', 'boardroom', 'event', 'events'])) return 'meeting';
  if (_has(s, ['office', 'offices', 'suite', 'studio'])) return 'office';
  if (_has(s, _fixedWords)) return 'fixed';
  if (_has(s, ['hot desk', 'hot-desk', 'hotdesk', 'flex', 'flexible', 'pass', 'coworking', 'co-working', 'desk', 'membership'])) {
    return 'shared';
  }
  return null;
}

/// What space: the name first, then the group it is filed in, and the
/// details last. A desk that includes "4 hour meeting room per month"
/// or an "address for head office" is still a desk (16 Nov 2026: two
/// of Avila Spaces' desks were read as a meeting room).
String _kindOf(Map<String, dynamic> p) {
  final byName = _kindIn(' ${p['name'] ?? ''} '.toLowerCase());
  if (byName != null) return byName;
  final cat = '${p['category'] ?? ''}';
  if (cat == 'meeting_room') return 'meeting';
  if (cat == 'private_office') return 'office';
  final s = _words(p);
  if (cat == 'coworking') return _has(s, _fixedWords) ? 'fixed' : 'shared';
  return _kindIn(s) ?? 'other';
}

/// Words that tell two levels of one product apart ("Fixed Desk Basic
/// Monthly", "Fixed Desk Premium Monthly"): not the same thing twice.
const _tierWords = {
  'basic', 'standard', 'premium', 'corporate', 'plus', 'pro', 'lite', 'light',
  'starter', 'essential', 'essentials', 'business', 'enterprise', 'executive',
  'gold', 'silver', 'bronze', 'platinum', 'vip', 'small', 'medium', 'large',
  'part', 'full', 'time', 'unlimited', 'limited', 'single', 'double', 'team',
  'person', 'people', 'pax', 'seat', 'seats', 'seater', 'for', 'up', 'to',
  's', 'm', 'l', 'xl', 'a', 'b', 'c', 'i', 'ii', 'iii',
};

/// True when two names are one product at two levels: what differs
/// between them is only level words or numbers.
bool _tiers(String a, String b) {
  Set<String> toks(String x) =>
      {for (final t in x.toLowerCase().split(RegExp(r'[^a-z0-9]+'))) if (t.isNotEmpty) t};
  final ta = toks(a), tb = toks(b);
  if (ta.intersection(tb).isEmpty) return false;
  final da = ta.difference(tb), db = tb.difference(ta);
  if (da.isEmpty && db.isEmpty) return false;
  bool level(String t) => _tierWords.contains(t) || RegExp(r'^\d+$').hasMatch(t);
  return da.every(level) && db.every(level);
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
    if (asked.add(key)) out.add(PriceIssue(key, see, ask));
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
      // two levels of one product (Basic and Premium) are not twins
      if (_tiers(a.name, b.name)) continue;
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
        '${_q(p.name)} shows "Price on request", while other prices for ${_kindWords[p.kind]} are shown. Is there a price, or is it the same as one of them?',
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

  // A pack of day passes against one day pass: more than buying them
  // one at a time, or less than a single one.
  for (final k in kinds) {
    final days = ps.where((p) => p.kind == k && p.period == 'day' && p.amount != null).toList();
    for (final pk in ps.where((p) => p.kind == k && p.period == 'pack' && p.amount != null)) {
      final n = _packCount(pk.name);
      if (n == null) continue;
      for (final d in days) {
        if (d.currency != pk.currency) continue;
        if (pk.amount! > d.amount! * n * 1.05) {
          add('pack:${pk.name}|${d.name}',
              '${_q(pk.name)} costs more than ${_q(d.name)} bought $n times.',
              '${_q(pk.name)} costs more than buying ${_q(d.name)} $n times. Is that right?');
        } else if (pk.amount! < d.amount!) {
          add('pack:${pk.name}|${d.name}',
              '${_q(pk.name)} costs less than one ${_q(d.name)}.',
              '${_q(pk.name)} costs less than one ${_q(d.name)}. Is that right, or has one of them a zero too many or too few?');
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
/// [firstName]: the owner's, when we know it ("Hi Amani,"); else the
/// space's team.
String priceCheckMessage(String spaceName, List<PriceIssue> issues, {String? firstName}) {
  final first = (firstName ?? '').trim();
  final team = first.isNotEmpty
      ? 'Hi $first,'
      : spaceName.trim().isEmpty
          ? 'Hi,'
          : 'Hi ${spaceName.trim()} team,';
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

// ------------------------------------------------------------ per what

/// The lengths a price can be for. Kept as the first detail line of a
/// product ("Per month"), which is how the pages already say it, so
/// nothing changes on the site (Jonathan, 9 Nov 2026: an owner's hot
/// desk and offices did not say per what, and the answer came by chat).
const pricePers = <(String, String)>[
  ('hour', 'Per hour'),
  ('day', 'Per day'),
  ('week', 'Per week'),
  ('month', 'Per month'),
  ('year', 'Per year'),
];

final _perLine = RegExp(r'^(price )?per (hour|day|week|month|year)\.?$', caseSensitive: false);

/// The "per" in [details] ("Per month" or "Price per month"), or null.
String? perOf(List<String> details) {
  for (final d in details) {
    final m = _perLine.firstMatch(d.trim());
    if (m != null) return m.group(2)!.toLowerCase();
  }
  return null;
}

/// [details] without their "per" line.
List<String> withoutPer(List<String> details) =>
    [for (final d in details) if (!_perLine.hasMatch(d.trim())) d];

/// [details] with [per] as the first line ("Per month"); none for null.
List<String> withPer(String? per, List<String> details) {
  final rest = withoutPer(details);
  final label = [for (final p in pricePers) if (p.$1 == per) p.$2];
  return [...label, ...rest];
}

/// A likely "per" from a product's name ("Day pass" is per day), or
/// null when the name does not say.
String? perFromName(String name) {
  final s = ' ${name.toLowerCase()} ';
  if (RegExp(r'\b([2-9]|[1-9][0-9]+)[ -]?(day|days)\b').hasMatch(s)) return null;
  if (RegExp(r'\b(hour|hourly)\b').hasMatch(s)) return 'hour';
  if (RegExp(r'\b(day|daily)\b').hasMatch(s)) return 'day';
  if (RegExp(r'\b(week|weekly)\b').hasMatch(s)) return 'week';
  if (RegExp(r'\b(month|monthly)\b').hasMatch(s)) return 'month';
  if (RegExp(r'\b(year|yearly|annual)\b').hasMatch(s)) return 'year';
  return null;
}
