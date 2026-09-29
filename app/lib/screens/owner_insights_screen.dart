import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/supabase_service.dart';
import '../theme.dart';

/// Control centre: what owners told us through the quick questions in
/// their Owner account (migration 104). Each question shows how the
/// answers split, every "Something else" in the owner's own words,
/// and for price questions how the answers change with the price
/// shown. Tap a question for who said what.
class OwnerInsightsScreen extends StatefulWidget {
  const OwnerInsightsScreen({super.key});
  @override
  State<OwnerInsightsScreen> createState() => _OwnerInsightsScreenState();
}

class _OwnerInsightsScreenState extends State<OwnerInsightsScreen> {
  final _supabase = SupabaseService();
  List<Map<String, dynamic>>? _rows;
  Map<String, dynamic> _ideas = {};
  bool _ideasOpen = false;
  String? _error;
  final Set<String> _open = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await _supabase.adminOwnerInsights();
      Map<String, dynamic> ideas = {};
      try {
        ideas = await _supabase.adminOwnerIdeas();
      } catch (_) {} // migration 106 not run yet: just no ideas card
      if (mounted) {
        setState(() {
          _ideas = ideas;
          _rows = rows;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _rows = [];
          _error = '$e'.contains('admin_owner_insights')
              ? 'Not installed yet: migration 104 has not run. Check the '
                  'last build on GitHub.'
              : 'Could not load: $e';
        });
      }
    }
  }

  /// "€9" and "$9" and "£9" are the same option in different
  /// currencies: count them together.
  static String _plain(String s) => s.replaceAll(RegExp(r'[€$£]'), '');

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    final total = rows == null
        ? 0
        : rows.fold<int>(0, (n, r) => n + ((r['answered'] as num?)?.toInt() ?? 0));
    return Scaffold(
      backgroundColor: Brand.bg,
      appBar: AppBar(title: const Text('What owners tell us')),
      body: rows == null
          ? const Center(child: CircularProgressIndicator(color: Brand.red))
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 48),
                children: [
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 820),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (_error != null)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: Text(_error!,
                                    style: const TextStyle(color: Brand.red)),
                              ),
                            Text(
                                '$total answer${total == 1 ? '' : 's'} so far. '
                                'Owners get one quick question at a time in their '
                                'Owner account, at most every 3 days unless they '
                                'ask for another. Price questions show each space '
                                'one price, the same every time, so the split '
                                'below shows how the answer moves with the price.',
                                style: const TextStyle(
                                    fontSize: 12.5,
                                    height: 1.45,
                                    color: Brand.inkSecondary)),
                            const SizedBox(height: 14),
                            if (_ideas.isNotEmpty) _ideasCard(),
                            for (final r in rows) _question(r),
                          ]),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  /// Build next: the ideas ranked by owners' votes, who voted, and the
  /// ideas owners wrote themselves (migration 106).
  Widget _ideasCard() {
    final ideas = List<Map<String, dynamic>>.from(
        ((_ideas['ideas'] ?? const []) as List)
            .map((x) => Map<String, dynamic>.from(x as Map)));
    final own = List<Map<String, dynamic>>.from(
        ((_ideas['suggestions'] ?? const []) as List)
            .map((x) => Map<String, dynamic>.from(x as Map)));
    final voters = (_ideas['voters_total'] as num?)?.toInt() ?? 0;
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Brand.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Brand.logoNavy.withValues(alpha: .35)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.lightbulb_outline, color: Brand.logoNavy, size: 20),
            const SizedBox(width: 8),
            const Expanded(
              child: Text('Build next: what owners voted for',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
            ),
            Text('$voters owner${voters == 1 ? '' : 's'} voted'
                '${own.isNotEmpty ? ' · ${own.length} own idea${own.length == 1 ? '' : 's'}' : ''}',
                style: const TextStyle(fontSize: 12, color: Brand.inkMuted)),
          ]),
          const SizedBox(height: 4),
          const Text(
              'From the Build next tab in the Owner account. Owners pick as '
              'many as they like, so the shares add up to more than 100%.',
              style: TextStyle(fontSize: 11.5, color: Brand.inkMuted)),
          const SizedBox(height: 12),
          for (final i in ideas)
            _bar(
                '${i['title']}${i['active'] == false ? ' (hidden)' : ''}',
                (i['votes'] as num?)?.toInt() ?? 0,
                voters),
          if (_ideasOpen) ...[
            const Divider(height: 22),
            const Text('WHO VOTED',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: .5,
                    color: Brand.inkSecondary)),
            const SizedBox(height: 6),
            for (final i in ideas)
              if ((i['voters'] as List? ?? const []).isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text.rich(TextSpan(
                      style: const TextStyle(fontSize: 12.5, height: 1.4),
                      children: [
                        TextSpan(
                            text: '${i['title']}: ',
                            style: const TextStyle(fontWeight: FontWeight.w700)),
                        TextSpan(
                            text: (i['voters'] as List).join(', '),
                            style: const TextStyle(color: Brand.inkSecondary)),
                      ])),
                ),
          ],
          if (voters > 0)
            TextButton(
                onPressed: () => setState(() => _ideasOpen = !_ideasOpen),
                child: Text(_ideasOpen ? 'Hide who voted' : 'Show who voted')),
          if (own.isNotEmpty) ...[
            const SizedBox(height: 6),
            const Text('THEIR OWN IDEAS',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: .5,
                    color: Brand.inkSecondary)),
            const SizedBox(height: 6),
            for (final o in own)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SelectableText('"${o['text']}"',
                          style: const TextStyle(fontSize: 13.5, height: 1.45)),
                      Text(
                          [
                            o['venue'] ?? o['email'] ?? 'An owner',
                            if ((o['city'] ?? '').toString().isNotEmpty) o['city'],
                            if (DateTime.tryParse('${o['at']}') != null)
                              DateFormat('d MMM')
                                  .format(DateTime.parse('${o['at']}').toLocal()),
                          ].join('  ·  '),
                          style: const TextStyle(
                              fontSize: 11.5, color: Brand.inkMuted)),
                    ]),
              ),
          ],
        ]),
      ),
    );
  }

  Widget _question(Map<String, dynamic> r) {
    final key = '${r['key']}';
    final options = List<String>.from((r['options'] ?? const []) as List);
    final answers = List<Map<String, dynamic>>.from(
        ((r['answers'] ?? const []) as List)
            .map((a) => Map<String, dynamic>.from(a as Map)));
    final n = answers.length;
    final skipped = (r['skipped'] as num?)?.toInt() ?? 0;
    final multi = r['multi'] == true;
    final isPrice = r['price_test'] is List;
    final open = _open.contains(key);

    // Count each option, matching on the text without currency signs.
    final counts = <String, int>{
      for (final o in options) _plain(o.replaceAll('{c}', '')): 0
    };
    for (final a in answers) {
      for (final c in List<String>.from((a['choices'] ?? const []) as List)) {
        final k = _plain(c);
        counts[k] = (counts[k] ?? 0) + 1;
      }
    }
    final others = answers
        .where((a) => (a['other'] ?? '').toString().trim().isNotEmpty)
        .toList();

    // Price questions: answers per price shown.
    final byPrice = <num, Map<String, int>>{};
    if (isPrice) {
      for (final a in answers) {
        final p = num.tryParse('${a['price'] ?? ''}');
        if (p == null) continue;
        final m = byPrice.putIfAbsent(p, () => {});
        for (final c in List<String>.from((a['choices'] ?? const []) as List)) {
          m[c] = (m[c] ?? 0) + 1;
        }
      }
    }
    final prices = byPrice.keys.toList()..sort();

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Brand.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Brand.border),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: n == 0
            ? null
            : () => setState(() => open ? _open.remove(key) : _open.add(key)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Text(
                    '${r['prompt']}'
                        .replaceAll('{c}', '')
                        .replaceAll('{price}', 'X'),
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 14.5, height: 1.35)),
              ),
              const SizedBox(width: 10),
              Text(
                  '$n answer${n == 1 ? '' : 's'}'
                  '${skipped > 0 ? ' · $skipped not now' : ''}'
                  '${r['active'] == false ? ' · paused' : ''}',
                  style: const TextStyle(fontSize: 12, color: Brand.inkMuted)),
            ]),
            if (multi)
              const Padding(
                padding: EdgeInsets.only(top: 2),
                child: Text('Owners could pick more than one.',
                    style: TextStyle(fontSize: 11.5, color: Brand.inkMuted)),
              ),
            const SizedBox(height: 10),
            if (n == 0)
              const Text('No answers yet.',
                  style: TextStyle(fontSize: 12.5, color: Brand.inkMuted))
            else ...[
              for (final e in (counts.entries.toList()
                    ..sort((a, b) => b.value.compareTo(a.value))))
                _bar(e.key, e.value, n),
              if (others.isNotEmpty) _bar('Something else', others.length, n),
            ],
            if (isPrice && prices.isNotEmpty) ...[
              const SizedBox(height: 10),
              const Text('BY PRICE SHOWN',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: .5,
                      color: Brand.inkSecondary)),
              const SizedBox(height: 6),
              for (final p in prices)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text.rich(TextSpan(
                      style: const TextStyle(fontSize: 12.5, height: 1.4),
                      children: [
                        TextSpan(
                            text: '${_money(p)}  ',
                            style: const TextStyle(fontWeight: FontWeight.w800)),
                        TextSpan(
                            text: byPrice[p]!
                                .entries
                                .map((e) => '${e.key} ${e.value}')
                                .join('  ·  '),
                            style: const TextStyle(color: Brand.inkSecondary)),
                      ])),
                ),
            ],
            if (others.isNotEmpty) ...[
              const SizedBox(height: 10),
              const Text('IN THEIR WORDS',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: .5,
                      color: Brand.inkSecondary)),
              const SizedBox(height: 6),
              for (final a in others)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text.rich(TextSpan(
                      style: const TextStyle(fontSize: 13, height: 1.45),
                      children: [
                        TextSpan(text: '"${a['other']}"  '),
                        TextSpan(
                            text: '${a['venue'] ?? 'a space'}',
                            style: const TextStyle(
                                fontSize: 12, color: Brand.inkMuted)),
                      ])),
                ),
            ],
            if (open) ...[
              const Divider(height: 22),
              const Text('WHO SAID WHAT',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: .5,
                      color: Brand.inkSecondary)),
              const SizedBox(height: 6),
              for (final a in answers) _who(a),
            ] else if (n > 0)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text('Show who said what',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Brand.accent)),
              ),
          ]),
        ),
      ),
    );
  }

  static String _money(num p) =>
      p == p.roundToDouble() ? p.toInt().toString() : p.toString();

  Widget _bar(String label, int count, int of) {
    final share = of == 0 ? 0.0 : count / of;
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
              child: Text(label,
                  style: const TextStyle(fontSize: 13, height: 1.3))),
          Text('$count  ·  ${(share * 100).round()}%',
              style: const TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w700, color: Brand.ink)),
        ]),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: share),
            duration: const Duration(milliseconds: 500),
            curve: Curves.easeOutCubic,
            builder: (_, v, __) => LinearProgressIndicator(
              value: v,
              minHeight: 7,
              backgroundColor: Brand.field,
              color: count == 0 ? Brand.inkFaint : Brand.accent,
            ),
          ),
        ),
      ]),
    );
  }

  Widget _who(Map<String, dynamic> a) {
    final when = DateTime.tryParse('${a['at']}')?.toLocal();
    final choices = List<String>.from((a['choices'] ?? const []) as List);
    final bits = [
      ...choices,
      if ((a['other'] ?? '').toString().trim().isNotEmpty) '"${a['other']}"',
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
            [
              a['venue'] ?? 'A space',
              [a['city'], a['country']]
                  .where((x) => (x ?? '').toString().isNotEmpty)
                  .join(', '),
              if (a['tier'] == 'verified') 'Verified' else 'Free',
              if (a['price'] != null) 'saw ${a['currency'] ?? ''}${a['price']}',
              if (when != null) DateFormat('d MMM').format(when),
            ].where((x) => '$x'.isNotEmpty).join('  ·  '),
            style: const TextStyle(fontSize: 11.5, color: Brand.inkMuted)),
        Text(bits.join(', '),
            style: const TextStyle(fontSize: 13, height: 1.4)),
      ]),
    );
  }
}
