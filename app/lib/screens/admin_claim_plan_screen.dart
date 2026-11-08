import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/supabase_service.dart';
import '../theme.dart';
import 'admin_outreach_screen.dart';
import 'admin_spaces_screen.dart';
import '../widgets/stat_grid.dart';

/// Control centre: Claim plan (migration 284).
///
/// Jonathan, 8 Nov 2026: "I just want to know what action to take with
/// each space, and to make sure it's recorded, so we can monitor", and
/// "an easy and simple overview of how many there are, how many are
/// done, maybe split between cafe and coworking and country".
///
/// Every page live on nomadwise.io that nobody has claimed, with its
/// one next step, worked out from what we know (email, phone,
/// Instagram, website, what happened in Outreach). Top: how far we
/// are, by type and by country. Below: the steps, most visited spaces
/// first; Open takes you to the space in Outreach, where "I sent it",
/// "Add an address" and "Log what they wrote" record it as before, and
/// the space moves on by itself.
class AdminClaimPlanScreen extends StatefulWidget {
  const AdminClaimPlanScreen({super.key});
  @override
  State<AdminClaimPlanScreen> createState() => _AdminClaimPlanScreenState();
}

const _red = Color(0xFFD42F3A);

/// The steps in the order to work through them: (key, title, how).
const _steps = <(String, String, String)>[
  ('replied', 'They wrote back: answer them',
      'Answer them in Outreach, and log what they wrote.'),
  ('looked', 'Opened their claim page',
      'Someone opened the claim page and stopped. Ask if they have any '
          'questions: Outreach picks that message for you.'),
  ('follow_up', 'Follow up',
      'Written to, no answer, and the follow-up date has come.'),
  ('email', 'Send the email',
      'Write the hello, send it from your own inbox, then press I sent it.'),
  ('check', 'Check the address first',
      'The address looks wrong (a press address, a typo, or marked Check '
          'first). Correct it with Add an address, then send.'),
  ('whatsapp', 'Send a WhatsApp',
      'No email, but a WhatsApp or phone number. Press WhatsApp: the message '
          'opens in WhatsApp ready to send. Then press I sent it.'),
  ('form', 'Use their contact form',
      'No email, but their website has a contact form. Press Contact form: '
          'the message is copied and the form opens. Paste, send, then press '
          'I sent it.'),
  ('instagram', 'Message on Instagram',
      'No email, phone or form. Press Instagram: the message is copied and '
          'their page opens. Paste it in a message, send, then press I sent it.'),
  ('facebook', 'Message on Facebook',
      'Only a Facebook page. Press Facebook: the message is copied and their '
          'page opens. Paste it in a message, send, then press I sent it.'),
  ('find', 'Find an email address',
      'They have a website but no address was found on it. Look on their '
          'site and put it on with Add an address. Claude can do a batch '
          'of these for you.'),
  ('covered', 'Covered by another space: nothing to do here',
      'Same company as a space that has an email (named on each one). That '
          'space shows "Also mention" with this page: send that one email, and '
          'this one counts as written to by itself.'),
  ('waiting', 'Written to: waiting',
      'Nothing to do until they answer or the follow-up date comes.'),
  ('nothing', 'No way in yet',
      'No email, phone, Instagram or website. Leave for now.'),
  ('put_aside', 'Put aside by us',
      'Not their answer: one of us parked these in Outreach ("Not now"), often '
          'because there was no way in then. To write to them, open the space '
          'in Outreach and press Bring back.'),
  ('stepped_off', 'Said no, unsubscribed or bounced',
      'They told us no, asked us not to write, or the email did not work. '
          'Leave them be.'),
];

// Collapsed groups with nothing to press (Jonathan, 8 Nov 2026, on
// Covered by another space: "I don't know what action to take with
// this"): the action lives on the space whose email covers them.
const _quiet = {'waiting', 'nothing', 'stepped_off', 'put_aside', 'covered'};

class _AdminClaimPlanScreenState extends State<AdminClaimPlanScreen> {
  final _supabase = SupabaseService();
  Map<String, dynamic>? _d;
  String? _error;
  String _kind = ''; // '', coworking, cafe
  String? _country;
  // Pull up one space, e.g. when a reply comes in on Facebook (Jonathan,
  // 8 Nov 2026): by name, place, email, phone, Instagram or Facebook.
  final _search = TextEditingController();
  String _q = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }
  bool _allCountries = false;
  final Set<String> _open = {};
  final Set<String> _all = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await _supabase.adminClaimPlan();
      if (mounted) {
        setState(() {
          _d = d;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _d = {};
          _error = '$e'.contains('admin_claim_plan')
              ? 'Not installed yet: migration 284 has not run. Check the last build on GitHub.'
              : 'Could not load: $e';
        });
      }
    }
  }

  List<Map<String, dynamic>> get _rowsAll => [
        for (final x in (_d?['rows'] as List? ?? const []))
          Map<String, dynamic>.from(x as Map)
      ];

  bool _kindOk(Object? k) => _kind.isEmpty || '$k' == _kind;

  /// What the row needs now: a company email already sent counts as
  /// reached.
  static String _step(Map<String, dynamic> r) =>
      r['action'] == 'covered' && r['covered_sent'] == true
          ? 'waiting'
          : '${r['action']}';

  @override
  Widget build(BuildContext context) {
    final d = _d;
    return Scaffold(
      backgroundColor: Brand.bg,
      appBar: AppBar(title: const Text('Claim plan'), actions: [
        IconButton(
            tooltip: 'Refresh', onPressed: _load, icon: const Icon(Icons.refresh)),
      ]),
      body: d == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
                children: [
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1100),
                      child: _error != null
                          ? Text(_error!, style: const TextStyle(color: _red))
                          : _body(),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _body() {
    final rows = _rowsAll.where((r) => _kindOk(r['kind'])).toList();
    final claimed = [
      for (final x in (_d?['claimed_list'] as List? ?? const []))
        Map<String, dynamic>.from(x as Map)
    ].where((r) => _kindOk(r['kind'])).toList();
    final here = _country == null
        ? rows
        : rows.where((r) => '${r['country']}' == _country).toList();
    final claimedHere = _country == null
        ? claimed
        : claimed.where((r) => '${r['country']}' == _country).toList();
    final words = _q.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isNotEmpty) {
      String hay(Map<String, dynamic> r) => [
            r['name'], r['city'], r['country'], r['email'], r['phone'],
            r['instagram'], r['facebook'], r['website'], r['covered_by'],
          ].where((x) => x != null).join(' ').toLowerCase();
      final found = _rowsAll.where((r) {
        final h = hay(r);
        return words.every(h.contains);
      }).toList();
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _searchBox(),
        const SizedBox(height: 12),
        Text(
            found.isEmpty
                ? 'No unclaimed space matches. (A space that has claimed is in Outreach.)'
                : '${found.length} ${found.length == 1 ? 'space' : 'spaces'} found',
            style: const TextStyle(fontSize: 13, color: Brand.inkSecondary)),
        const SizedBox(height: 8),
        if (found.isNotEmpty)
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Brand.border),
            ),
            child: Column(children: [
              for (final r in found.take(40)) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 10, 18, 0),
                  child: Text(
                      (_steps.firstWhere((x) => x.$1 == _step(r), orElse: () => ('', '', '')).$2)
                          .toUpperCase(),
                      style: const TextStyle(
                          fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: .6,
                          color: Brand.inkMuted)),
                ),
                _row(r),
                const Divider(height: 1, color: Brand.hairline),
              ],
            ]),
          ),
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _searchBox(),
      const SizedBox(height: 12),
      _filters(),
      const SizedBox(height: 16),
      _overview(here, claimedHere),
      const SizedBox(height: 20),
      _splits(rows, claimed),
      const SizedBox(height: 24),
      const Text('What to do next',
          style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
      const SizedBox(height: 4),
      Text(
          'Most visited first. Open takes you to the space in Outreach; what '
          'you do there is recorded and the space moves on by itself.'
          '${_country != null ? ' Showing $_country only.' : ''}',
          style: const TextStyle(fontSize: 13, color: Brand.inkSecondary, height: 1.4)),
      const SizedBox(height: 12),
      for (final s in _steps)
        if (here.any((r) => _step(r) == s.$1))
          _stepCard(s, here.where((r) => _step(r) == s.$1).toList()),
    ]);
  }

  Widget _searchBox() => TextField(
        controller: _search,
        onChanged: (v) => setState(() => _q = v),
        decoration: InputDecoration(
          hintText: 'Find a space: name, place, email, phone, Instagram or Facebook',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: _q.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Clear',
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(() {
                        _search.clear();
                        _q = '';
                      })),
          isDense: true,
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: Brand.border)),
        ),
      );

  Widget _filters() => Wrap(spacing: 8, runSpacing: 8, children: [
        for (final k in const [('', 'All'), ('coworking', 'Coworking'), ('cafe', 'Cafes')])
          ChoiceChip(
            label: Text(k.$2),
            selected: _kind == k.$1,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            onSelected: (_) => setState(() => _kind = k.$1),
          ),
        if (_country != null)
          InputChip(
            label: Text(_country!),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            onDeleted: () => setState(() => _country = null),
          ),
      ]);

  Widget _card(Widget child) => Container(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Brand.border),
        ),
        child: child,
      );

  Widget _overview(List<Map<String, dynamic>> rows, List<Map<String, dynamic>> claimed) {
    final total = rows.length + claimed.length;
    final reached = rows.where((r) => r['reached'] == true).length;
    final todo = rows
        .where((r) => !_quiet.contains(_step(r)) && r['reached'] != true)
        .length;
    final done = reached + claimed.length;
    final share = total == 0 ? 0.0 : done / total;
    final round1 = rows.where((r) => r['round1'] == true).length;
    final round1Sent =
        rows.where((r) => r['round1'] == true && r['last_out_at'] != null).length;
    final closed = ((_d?['closed'] as num?) ?? 0).toInt();
    return _card(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(_country == null ? 'How far we are' : 'How far we are in $_country',
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
      const SizedBox(height: 12),
      StatGrid(stats: [
        ('$total', 'spaces live', null),
        ('${claimed.length}', 'claimed', Brand.success),
        ('$reached', 'written to, not claimed', null),
        ('$todo', 'with something to do', null),
        ('${rows.where((r) => _step(r) == 'nothing').length}', 'no way in yet', null),
      ]),
      const SizedBox(height: 14),
      ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: LinearProgressIndicator(
          value: share.clamp(0, 1).toDouble(),
          minHeight: 10,
          backgroundColor: Brand.field,
          color: Brand.success,
        ),
      ),
      const SizedBox(height: 6),
      Text('${(share * 100).round()}% claimed or written to',
          style: const TextStyle(fontSize: 12.5, color: Brand.inkSecondary)),
      if (round1 > 0) ...[
        const SizedBox(height: 10),
        Text('Round 1: $round1Sent of $round1 sent',
            style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
      ],
      if (closed > 0 && _country == null) ...[
        const SizedBox(height: 8),
        Text(
            'Not counted: $closed more pages are marked closed for good on Google. '
            'They are for Quality to check, not to write to.',
            style: const TextStyle(fontSize: 12.5, color: Brand.inkMuted, height: 1.4)),
      ],
    ]));
  }

  /// Spaces, claimed, written to and left, by type and by country.
  Widget _splits(List<Map<String, dynamic>> rows, List<Map<String, dynamic>> claimed) {
    Map<String, List<int>> group(String Function(Map<String, dynamic>) key) {
      // [spaces, claimed, written to, left with something to do]
      final m = <String, List<int>>{};
      for (final r in rows) {
        final k = key(r);
        final g = m.putIfAbsent(k, () => [0, 0, 0, 0]);
        g[0]++;
        if (r['reached'] == true) {
          g[2]++;
        } else if (!_quiet.contains(_step(r))) {
          g[3]++;
        }
      }
      for (final r in claimed) {
        final g = m.putIfAbsent(key(r), () => [0, 0, 0, 0]);
        g[0]++;
        g[1]++;
      }
      return m;
    }

    final narrow = MediaQuery.sizeOf(context).width < 600;
    final cw = narrow ? 50.0 : 72.0;
    String kindName(String k) =>
        k == 'coworking' ? 'Coworking' : k == 'cafe' ? 'Cafes' : (k.isEmpty ? 'Other' : k);
    final byKind = group((r) => '${r['kind'] ?? ''}');
    final byCountry = group((r) {
      final c = '${r['country'] ?? ''}'.trim();
      return c.isEmpty ? 'Unknown' : c;
    });
    final countries = byCountry.entries.toList()
      ..sort((a, b) => b.value[0].compareTo(a.value[0]));
    final shown = _allCountries ? countries : countries.take(12).toList();

    Widget head(String first) => Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(children: [
            Expanded(
                child: Text(first,
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w700, color: Brand.inkMuted))),
            for (final h in narrow
                ? const ['Spaces', 'Claimed', 'Written', 'To do']
                : const ['Spaces', 'Claimed', 'Written to', 'To do'])
              SizedBox(
                  width: cw,
                  child: Text(h,
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w700, color: Brand.inkMuted))),
          ]),
        );

    Widget line(String name, List<int> g, {VoidCallback? onTap, bool on = false}) {
      final done = g[0] == 0 ? 0.0 : (g[1] + g[2]) / g[0];
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 4),
          decoration: BoxDecoration(
            color: on ? Brand.accentTint : null,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(
                  child: Text(name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14))),
              for (final (i, n) in [(0, g[0]), (1, g[1]), (2, g[2]), (3, g[3])])
                SizedBox(
                    width: cw,
                    child: Text('$n',
                        textAlign: TextAlign.right,
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: i == 0 ? FontWeight.w700 : FontWeight.w500,
                            color: i == 1 && n > 0 ? Brand.success : Brand.ink))),
            ]),
            const SizedBox(height: 5),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: done.clamp(0, 1).toDouble(),
                minHeight: 4,
                backgroundColor: Brand.field,
                color: Brand.success,
              ),
            ),
          ]),
        ),
      );
    }

    final kinds = byKind.entries.toList()..sort((a, b) => b.value[0].compareTo(a.value[0]));
    return _card(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Text('By type and country',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
      const SizedBox(height: 4),
      const Text(
          'The green line is how much is claimed or written to. Tap a country to '
          'see only its spaces below.',
          style: TextStyle(fontSize: 13, color: Brand.inkSecondary, height: 1.4)),
      const SizedBox(height: 14),
      head('Type'),
      for (final e in kinds) line(kindName(e.key), e.value),
      const SizedBox(height: 18),
      head('Country'),
      for (final e in shown)
        line(e.key, e.value,
            on: _country == e.key,
            onTap: () => setState(() => _country = _country == e.key ? null : e.key)),
      if (countries.length > 12)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () => setState(() => _allCountries = !_allCountries),
            child: Text(_allCountries
                ? 'Show fewer'
                : 'Show all ${countries.length} countries'),
          ),
        ),
    ]));
  }

  Widget _stepCard((String, String, String) s, List<Map<String, dynamic>> list) {
    final open = _open.contains(s.$1) || (!_quiet.contains(s.$1) && !_open.contains('-${s.$1}'));
    final all = _all.contains(s.$1);
    final shown = all ? list : list.take(8).toList();
    final quiet = _quiet.contains(s.$1);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Brand.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => setState(() {
            if (open) {
              _open.remove(s.$1);
              _open.add('-${s.$1}');
            } else {
              _open.remove('-${s.$1}');
              _open.add(s.$1);
            }
          }),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 12, 14),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(s.$2,
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: quiet ? Brand.inkSecondary : Brand.ink)),
                  const SizedBox(height: 3),
                  Text(s.$3,
                      style: const TextStyle(
                          fontSize: 13, color: Brand.inkSecondary, height: 1.4)),
                ]),
              ),
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                decoration: BoxDecoration(
                  color: quiet ? Brand.field : Brand.accentTint,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text('${list.length}',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: quiet ? Brand.inkSecondary : _red)),
              ),
              Icon(open ? Icons.expand_less : Icons.expand_more, color: Brand.inkMuted),
            ]),
          ),
        ),
        if (open) ...[
          const Divider(height: 1, color: Brand.hairline),
          for (final r in shown) _row(r),
          if (list.length > 8)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 2, 10, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => setState(() => all ? _all.remove(s.$1) : _all.add(s.$1)),
                  child: Text(all ? 'Show fewer' : 'Show all ${list.length}'),
                ),
              ),
            ),
        ],
      ]),
    );
  }

  /// Spaces of the same company whose only way in is this space's email.
  List<Map<String, dynamic>> _covers(Map<String, dynamic> r) {
    final name = '${r['name']}'.trim().toLowerCase();
    return _rowsAll
        .where((x) =>
            x['action'] == 'covered' &&
            x['covered_sent'] != true &&
            '${x['covered_by'] ?? ''}'.trim().toLowerCase() == name)
        .toList();
  }

  String _detail(Map<String, dynamic> r) {
    String host(Object? u) {
      final s = '$u'.trim();
      final p = Uri.tryParse(s.startsWith('http') ? s : 'https://$s');
      return (p?.host ?? s).replaceFirst('www.', '');
    }

    String ig(Object? u) {
      final s = '$u'.trim();
      final m = RegExp(r'instagram\.com/([^/?#]+)').firstMatch(s);
      return m != null ? '@${m.group(1)}' : s;
    }

    final sent = DateTime.tryParse('${r['last_out_at'] ?? ''}')?.toLocal();
    return switch (_step(r)) {
      'email' || 'check' => '${r['email'] ?? ''}',
      'whatsapp' => '${r['phone'] ?? ''}',
      'instagram' => ig(r['instagram']),
      'facebook' => '${r['facebook']}'.replaceFirst(RegExp(r'^https?://(www\.)?'), ''),
      'form' => host(r['form']),
      'find' => host(r['website']),
      'covered' => 'Reached when you send the email to ${r['covered_by']}',
      'waiting' || 'follow_up' => sent != null
          ? 'Written to ${DateFormat('d MMM').format(sent)}'
          : (r['covered_by'] != null ? 'Covered by the email to ${r['covered_by']}' : ''),
      _ => '${r['email'] ?? r['phone'] ?? ''}',
    };
  }

  Widget _row(Map<String, dynamic> r) {
    final place = [
      if ('${r['city'] ?? ''}'.trim().isNotEmpty) '${r['city']}'.trim(),
      if ('${r['country'] ?? ''}'.trim().isNotEmpty) '${r['country']}'.trim(),
    ].join(', ');
    final kind = r['kind'] == 'cafe' ? 'Cafe' : 'Coworking';
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 10, 12, 10),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(
                child: InkWell(
                  onTap: () async {
                    await Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => SpaceProfileScreen(
                            venueId: '${r['venue_id']}', name: '${r['name']}')));
                    _load();
                  },
                  child: Text('${r['name']}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          decoration: TextDecoration.underline,
                          decorationColor: Brand.inkFaint)),
                ),
              ),
              if (r['round1'] == true) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                      color: Brand.goldTint, borderRadius: BorderRadius.circular(8)),
                  child: const Text('Round 1',
                      style: TextStyle(
                          fontSize: 11, fontWeight: FontWeight.w700, color: Brand.goldTextDark)),
                ),
              ],
            ]),
            const SizedBox(height: 2),
            Text(
                '$kind · ${place.isEmpty ? 'place unknown' : place} · ${r['views'] ?? 0} views in 90 days',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5, color: Brand.inkMuted)),
            if (_detail(r).isNotEmpty)
              Text(_detail(r),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5, color: Brand.inkSecondary)),
            // The same company's other spaces this email covers: name
            // their pages in it too.
            if (r['last_out_at'] == null && _covers(r).isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(
                    'Also mention: ${_covers(r).map((x) => '${x['name']} (nomadwise.io/coworking/${x['slug']})').join(', ')}',
                    style: const TextStyle(
                        fontSize: 12.5, fontWeight: FontWeight.w600, color: Brand.goldTextDark)),
              ),
          ]),
        ),
        const SizedBox(width: 10),
        _actions(r),
      ]),
    );
  }

  // ------------------------------------------------------------ acting

  Future<void> _openInOutreach(Map<String, dynamic> r) async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => AdminOutreachScreen(initialQuery: '${r['name']}')));
    _load();
  }

  static const _channelNames = {
    'whatsapp': 'WhatsApp',
    'form': 'Contact form',
    'instagram': 'Instagram',
    'facebook': 'Facebook',
  };

  /// The ways in this space has, besides email.
  List<String> _ways(Map<String, dynamic> r) => [
        if ('${r['phone'] ?? ''}'.trim().isNotEmpty) 'whatsapp',
        if ('${r['form'] ?? ''}'.trim().isNotEmpty) 'form',
        if ('${r['instagram'] ?? ''}'.trim().isNotEmpty) 'instagram',
        if ('${r['facebook'] ?? ''}'.trim().isNotEmpty) 'facebook',
      ];

  /// The main button for the row's step, and a menu with every other way
  /// in, so a space can be reached however suits it.
  Widget _actions(Map<String, dynamic> r) {
    final step = _step(r);
    final ways = _ways(r);
    final main = _channelNames.containsKey(step) && r['contact_id'] != null ? step : null;
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(8));
    return Row(mainAxisSize: MainAxisSize.min, children: [
      OutlinedButton(
        onPressed: () => main == null ? _openInOutreach(r) : _message(r, main),
        style: OutlinedButton.styleFrom(shape: shape),
        child: Text(main == null ? 'Open' : _channelNames[main]!),
      ),
      PopupMenuButton<String>(
        tooltip: 'Other ways in',
        icon: const Icon(Icons.more_vert, size: 20, color: Brand.inkSecondary),
        shape: shape,
        onSelected: (k) => k == 'outreach' ? _openInOutreach(r) : _message(r, k),
        itemBuilder: (_) => [
          PopupMenuItem(
              value: 'outreach',
              child: Text('${r['email'] != null ? 'Email: ' : ''}Open in Outreach')),
          if (r['contact_id'] != null)
            for (final k in ways)
              if (k != main) PopupMenuItem(value: k, child: Text(_channelNames[k]!)),
        ],
      ),
    ]);
  }

  /// A message on WhatsApp, a contact form, Instagram or Facebook: the
  /// words from the template, copied (or put straight into WhatsApp), their
  /// page opened, and "I sent it" to record it on the space's Outreach card
  /// like the same buttons in Outreach. Nothing is sent from here.
  Future<void> _message(Map<String, dynamic> r, String channel) async {
    final id = '${r['contact_id'] ?? ''}';
    if (id.isEmpty) return;
    final label = _channelNames[channel]!;
    final step = _step(r);
    final form = channel == 'form';
    final key = switch (step) {
      'looked' => form ? 'claim_looked' : 'claim_looked_wa',
      'follow_up' => form ? 'followup_after_ours' : 'followup_after_ours_wa',
      _ => r['last_out_at'] == null
          ? (form ? 'invite_listed' : 'invite_listed_wa')
          : (form ? 'claim_looked' : 'claim_looked_wa'),
    };
    final text = TextEditingController();
    var busy = true;
    var opened = false;
    var started = false;
    String? problem;
    DateTime? openedAt;

    Uri? link(String raw) {
      final t = raw.trim();
      if (t.isEmpty) return null;
      if (!t.contains('/') && !t.contains('.')) {
        return Uri.tryParse('https://www.instagram.com/${t.replaceAll('@', '')}');
      }
      return Uri.tryParse(t.contains('://') ? t : 'https://$t');
    }

    Uri? where() {
      switch (channel) {
        case 'whatsapp':
          final digits = '${r['phone'] ?? ''}'.replaceAll(RegExp(r'[^0-9]'), '');
          if (digits.isEmpty) return null;
          return Uri.parse('https://wa.me/$digits?text=${Uri.encodeComponent(text.text.trim())}');
        case 'form':
          return link('${r['form'] ?? r['website'] ?? ''}');
        case 'instagram':
          return link('${r['instagram'] ?? ''}');
        default:
          return link('${r['facebook'] ?? ''}');
      }
    }

    Future<void> fill(void Function(void Function()) setD) async {
      var body = '';
      try {
        final p = await _supabase.outreachPreview(id, key);
        body = '${p['body'] ?? ''}';
      } catch (_) {}
      // The claim link says where it was sent, so a visit through it is
      // known as an answer to this message.
      text.text = body
          .replaceAll('from=whatsapp', 'from=${form ? 'email' : channel}')
          .replaceAll('from=email', 'from=${form ? 'email' : channel}');
      setD(() => busy = false);
    }

    final sent = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        if (!started) {
          started = true;
          WidgetsBinding.instance.addPostFrameCallback((_) => fill(setD));
        }
        final target = busy ? null : where();
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          title: Text('$label message to ${r['name']}'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(
                  controller: text,
                  readOnly: opened,
                  minLines: 4,
                  maxLines: 10,
                  decoration: InputDecoration(
                      labelText: busy ? 'Getting the message...' : 'Message',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8))),
                ),
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                        backgroundColor: Brand.red,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                    onPressed: target == null
                        ? null
                        : () async {
                            // Copy first, while the press still counts: a
                            // browser blocks a new tab opened after a wait.
                            final copy = Clipboard.setData(ClipboardData(text: text.text.trim()));
                            launchUrl(target, mode: LaunchMode.externalApplication)
                                .catchError((_) => false);
                            openedAt ??= DateTime.now();
                            try {
                              await copy;
                            } catch (_) {}
                            setD(() {
                              opened = true;
                              problem = null;
                            });
                          },
                    icon: const Icon(Icons.open_in_new, size: 16),
                    label: Text(channel == 'whatsapp'
                        ? 'Open in WhatsApp'
                        : 'Copy, and open their ${form ? 'contact form' : label}'),
                  ),
                ),
                if (problem != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(problem!, style: const TextStyle(color: _red, fontSize: 13)),
                  ),
                const SizedBox(height: 8),
                Text(
                    opened
                        ? (channel == 'whatsapp'
                            ? 'Send it in WhatsApp, then press I sent it so it is recorded.'
                            : 'The message is copied. Paste it there and send, then press '
                                'I sent it so it is recorded.')
                        : (channel == 'whatsapp'
                            ? 'If the number is not on WhatsApp, WhatsApp says so: then try '
                                'another way in from the menu.'
                            : 'Nothing is sent from here: you paste and send it yourself.'),
                    style: const TextStyle(fontSize: 12, height: 1.4, color: Brand.inkMuted)),
              ]),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(opened ? 'Not sent' : 'Cancel')),
            if (opened)
              FilledButton(
                style: FilledButton.styleFrom(
                    backgroundColor: Brand.red,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                onPressed: () async {
                  try {
                    await _supabase.outreachLogMessage(id, text.text.trim(), channel,
                        at: openedAt);
                    if (ctx.mounted) Navigator.pop(ctx, true);
                  } catch (e) {
                    setD(() => problem = 'Could not record it: $e');
                  }
                },
                child: const Text('I sent it'),
              ),
          ],
        );
      }),
    );
    text.dispose();
    if (sent == true) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Recorded as sent on $label.')));
      }
      _load();
    }
  }
}
