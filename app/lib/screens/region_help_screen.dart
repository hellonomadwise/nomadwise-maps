import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import '../services/supabase_service.dart';
import '../theme.dart';

/// What the founder chose: an existing Region (its Webflow id and
/// name), 'new' with the name and state of a Region to create, or
/// 'other' to open the full list of Regions.
class RegionChoice {
  final String id;
  final String? name;
  final String? state;
  const RegionChoice(this.id, [this.name, this.state]);
}

/// Which Region a space belongs to: the nearest Regions on the site
/// with their distance, a first verdict, and "Ask Claude" (migration
/// 189), the same way the Location is chosen on the map of the spaces
/// nearby. Jonathan, 20 Oct 2026: "can you set it similar to how to
/// choose a location, in terms of ask claude etc".
///
/// Pops a [RegionChoice] when a Region is chosen, nothing otherwise.
class RegionHelpScreen extends StatefulWidget {
  final String venueId;
  final String venueName;
  const RegionHelpScreen(
      {super.key, required this.venueId, required this.venueName});

  @override
  State<RegionHelpScreen> createState() => _RegionHelpScreenState();
}

class _RegionHelpScreenState extends State<RegionHelpScreen> {
  final _supabase = SupabaseService();

  Map<String, dynamic>? _help;
  String? _error;
  bool _loading = true;

  // The Region picked (a Webflow id), or a new one picked from
  // Claude's answer (its name and state).
  String? _picked;
  bool _pickedByHand = false;
  String? _pickedNew;
  String? _pickedNewState;

  // Asking Claude: the question's number, its answer, and the
  // founder's reason, kept with his choice so later answers learn.
  int? _askId;
  bool _asking = false;
  Map<String, dynamic>? _answer;
  String? _askError;
  final _reason = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  static String _plain(Object e) => e is PostgrestException
      ? e.message
      : '$e'.replaceFirst('Exception: ', '');

  static List<Map<String, dynamic>> _maps(Object? list) => [
        for (final x in (list is List ? list : const []))
          if (x is Map) Map<String, dynamic>.from(x),
      ];

  static Map<String, dynamic> _map(Object? x) =>
      x is Map ? Map<String, dynamic>.from(x) : const <String, dynamic>{};

  Future<void> _load() async {
    setState(() {
      _loading = _help == null;
      _error = null;
    });
    try {
      final h = await _supabase.regionHelp(widget.venueId);
      if (!mounted) return;
      final verdict = _map(h['verdict']);
      setState(() {
        _help = h;
        _loading = false;
        if (!_pickedByHand && verdict['verdict'] == 'suggest') {
          final id = '${verdict['region_id'] ?? ''}';
          _picked = id.isEmpty ? null : id;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _plain(e);
      });
    }
  }

  /// Sends the question, then reads the answer every two seconds for
  /// up to a minute and a half.
  Future<void> _ask() async {
    setState(() {
      _asking = true;
      _askError = null;
      _answer = null;
    });
    try {
      final id = await _supabase.regionAsk(widget.venueId);
      _askId = id;
      for (var i = 0; i < 45; i++) {
        await Future.delayed(const Duration(seconds: 2));
        if (!mounted) return;
        final a = await _supabase.regionAnswer(id);
        final status = '${a['status'] ?? ''}';
        if (status == 'waiting') continue;
        if (!mounted) return;
        setState(() {
          _asking = false;
          if (status == 'done') {
            _answer = a;
            // The first option is pre-selected, unless one was picked
            // by hand.
            final first = _maps(a['options']).firstOrNull;
            if (first != null && !_pickedByHand) _select(first);
          } else {
            _askError = '${a['error'] ?? 'Something went wrong.'}';
          }
        });
        return;
      }
      if (!mounted) return;
      setState(() {
        _asking = false;
        _askError = 'No answer after a minute and a half. Try again.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _asking = false;
        _askError = _plain(e);
      });
    }
  }

  /// One of Claude's options becomes the choice (no setState: callers
  /// wrap it).
  void _select(Map<String, dynamic> o) {
    final rid = '${o['region_id'] ?? ''}';
    if (o['kind'] == 'existing' && rid.isNotEmpty) {
      _picked = rid;
      _pickedNew = null;
      _pickedNewState = null;
    } else {
      _picked = null;
      _pickedNew = '${o['name'] ?? ''}';
      final st = '${o['state'] ?? ''}'.trim();
      _pickedNewState = st.isEmpty ? null : st;
    }
  }

  void _pick(String id) => setState(() {
        _picked = _picked == id ? null : id;
        _pickedNew = null;
        _pickedNewState = null;
        _pickedByHand = true;
      });

  /// Keeps what was chosen after asking (and why), then closes with
  /// that choice.
  Future<void> _finish(RegionChoice choice) async {
    final id = _askId;
    // "Make a new Region myself" has no name yet: nothing to learn.
    if (id != null &&
        _answer != null &&
        choice.id != 'other' &&
        (choice.name ?? '').trim().isNotEmpty) {
      final kind = choice.id == 'new' ? 'new' : 'existing';
      try {
        await _supabase.regionAskChosen(id,
            kind: kind,
            name: choice.name,
            regionId: kind == 'existing' ? choice.id : null,
            reason: _reason.text.trim().isEmpty ? null : _reason.text.trim());
      } catch (_) {
        // Not keeping the lesson never stops the choice.
      }
    }
    if (!mounted) return;
    Navigator.of(context).pop(choice);
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.venueName.trim().isEmpty
        ? 'this space'
        : widget.venueName.trim();
    return Scaffold(
      appBar: AppBar(title: Text('Which Region for $name?')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null && _help == null
              ? _message('This could not be loaded.\n$_error')
              : _body(_help ?? const {}),
    );
  }

  Widget _message(String text) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(text,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 14, height: 1.45, color: Brand.inkSecondary)),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _load, child: const Text('Try again')),
          ]),
        ),
      );

  static const _small =
      TextStyle(fontSize: 12.5, height: 1.4, color: Brand.inkSecondary);
  static const _label = TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w800,
      letterSpacing: .4,
      color: Brand.inkMuted);

  Widget _body(Map<String, dynamic> h) {
    final venue = _map(h['venue']);
    final regions = _maps(h['regions']);
    final verdict = _map(h['verdict']);
    final country = '${venue['country'] ?? ''}'.trim();
    final isUs = country.toLowerCase() == 'united states';

    String? pickedName;
    for (final r in regions) {
      if ('${r['id']}' == _picked) pickedName = '${r['name'] ?? ''}';
    }
    if (pickedName == null && _picked != null) {
      for (final o in _maps(_answer?['options'])) {
        if ('${o['region_id'] ?? ''}' == _picked) {
          pickedName = '${o['name'] ?? ''}';
        }
      }
    }

    final where = [
      venue['city'],
      venue['county'],
      venue['state'],
      venue['country'],
    ].where((x) => x != null && '$x'.trim().isNotEmpty).join(', ');

    return ListView(padding: EdgeInsets.zero, children: [
      _verdictBox(verdict),
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if ('${venue['address'] ?? ''}'.isNotEmpty)
            Text('${venue['address']}',
                style: const TextStyle(
                    fontSize: 13.5, fontWeight: FontWeight.w600)),
          if (where.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text('Google: $where', style: _small),
            ),
          if (isUs) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                  color: Brand.field, borderRadius: BorderRadius.circular(10)),
              child: const Text(
                  'In the United States a Region is one city or metro area, '
                  'written City, ST: Duluth, MN. The state is not a Region; '
                  'it goes in the page address. A suburb goes under its big '
                  "city's Region.",
                  style: _small),
            ),
          ],
          const SizedBox(height: 14),
          const Text('NEAREST REGIONS ON THE SITE', style: _label),
          const SizedBox(height: 6),
          if (regions.isEmpty)
            const Text('None found near this space.', style: _small)
          else
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final r in regions.take(8)) _regionChip(r),
            ]),
          const SizedBox(height: 14),
          _askSection(),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 4, children: [
            if ((_pickedNew ?? '').isNotEmpty)
              ElevatedButton(
                  onPressed: () => _finish(
                      RegionChoice('new', _pickedNew, _pickedNewState)),
                  child: Text('Create "$_pickedNew" as a new Region'))
            else
              ElevatedButton(
                  onPressed: _picked == null || (pickedName ?? '').isEmpty
                      ? null
                      : () => _finish(RegionChoice(_picked!, pickedName)),
                  child: Text((pickedName ?? '').isNotEmpty
                      ? 'Use $pickedName'
                      : 'Choose a Region above')),
            TextButton(
                onPressed: () => _finish(const RegionChoice('new')),
                child: const Text('Make a new Region myself')),
            TextButton(
                onPressed: () =>
                    Navigator.of(context).pop(const RegionChoice('other')),
                child: const Text('Full list')),
          ]),
        ]),
      ),
    ]);
  }

  Widget _regionChip(Map<String, dynamic> r) {
    final id = '${r['id']}';
    final on = _picked == id && _pickedNew == null;
    final km = r['km'];
    final kmText = km is num
        ? (km < 10 ? km.toStringAsFixed(1) : km.round().toString())
        : '?';
    return Material(
      color: on ? Brand.logoTealTint : Brand.surface,
      shape: StadiumBorder(
          side: BorderSide(color: on ? Brand.logoNavy : Brand.border)),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: () => _pick(id),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Text('${r['name'] ?? ''} · $kmText km',
              style: const TextStyle(
                  fontSize: 12.5, fontWeight: FontWeight.w600)),
        ),
      ),
    );
  }

  Widget _verdictBox(Map<String, dynamic> verdict) {
    final kind = '${verdict['verdict'] ?? 'none'}';
    final region = '${verdict['region'] ?? ''}'.trim();
    final why = '${verdict['why'] ?? ''}'.trim();
    final (String title, Color tint, Color ink) = kind == 'suggest'
        ? ('Suggested: $region', Brand.goldTint, Brand.goldTextDark)
        : ('No Region suggested', Brand.field, Brand.inkSecondary);
    return Container(
      width: double.infinity,
      color: tint,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title,
            style: TextStyle(
                fontSize: 14, fontWeight: FontWeight.w800, color: ink)),
        if (why.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(why,
                style: TextStyle(fontSize: 12.5, height: 1.4, color: ink)),
          ),
      ]),
    );
  }

  /// "Ask Claude": the button, then the options to choose from (each
  /// with its reason) and a box for the founder's own reason.
  Widget _askSection() {
    final answer = _answer;
    final options = _maps(answer?['options']);
    final note = '${answer?['note'] ?? ''}'.trim();

    Widget option(Map<String, dynamic> o) {
      final isNew = o['kind'] != 'existing' ||
          '${o['region_id'] ?? ''}'.isEmpty;
      final name = '${o['name'] ?? ''}';
      final rid = '${o['region_id'] ?? ''}';
      final on = isNew
          ? _pickedNew == name
          : (_picked == rid && _pickedNew == null);
      final reason = '${o['reason'] ?? ''}'.trim();
      final conf = '${o['confidence'] ?? ''}';
      return Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Material(
          color: on ? Brand.logoTealTint : Brand.surface,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: BorderSide(color: on ? Brand.logoNavy : Brand.border)),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => setState(() {
              _pickedByHand = true;
              _select(o);
            }),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                        on
                            ? Icons.radio_button_checked
                            : Icons.radio_button_off,
                        size: 18,
                        color: on ? Brand.logoNavy : Brand.inkMuted),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                                [
                                  name,
                                  if (isNew) '(new Region)',
                                  if (conf.isNotEmpty) '· $conf confidence',
                                ].join(' '),
                                style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700)),
                            if (reason.isNotEmpty) Text(reason, style: _small),
                          ]),
                    ),
                  ]),
            ),
          ),
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
          color: Brand.field, borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Expanded(child: Text('ASK CLAUDE', style: _label)),
          TextButton.icon(
              onPressed: _asking ? null : _ask,
              icon: const Icon(Icons.auto_awesome_outlined, size: 16),
              label: Text(answer == null ? 'Ask Claude' : 'Ask again')),
        ]),
        if (_asking) ...[
          const LinearProgressIndicator(minHeight: 2),
          const SizedBox(height: 6),
          const Text('Asking Claude. This takes up to half a minute.',
              style: _small),
        ] else if (_askError != null)
          Text(_askError!,
              style: const TextStyle(fontSize: 12.5, color: Brand.red))
        else if (answer == null)
          const Text(
              'Claude looks at the address, the nearest Regions on the '
              'site, how Regions in this country are named and your '
              'earlier choices, and offers the options.',
              style: _small)
        else ...[
          if (options.isEmpty)
            Text(
                'No option came back${note.isEmpty ? '.' : ': $note'} '
                'Pick from the full list.',
                style: _small)
          else ...[
            if (note.isNotEmpty) ...[
              Text(note, style: _small),
              const SizedBox(height: 6),
            ],
            ...options.map(option),
          ],
          const SizedBox(height: 4),
          TextField(
            controller: _reason,
            minLines: 1,
            maxLines: 3,
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: Brand.surface,
                hintText: 'Why this choice? (optional; Claude learns from it)',
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none)),
          ),
        ],
      ]),
    );
  }
}
