import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/supabase_service.dart';
import '../theme.dart';
import '../widgets/pricing_picker.dart';

/// Pricing (migration 115): the four country groups with their euro
/// prices and Stripe price ids, the amounts Stripe holds in every
/// currency, every country's group and default currency, and any
/// country name in the database that is not recognised yet. Founders
/// only. Nothing here charges anyone: the prices live in Stripe, and
/// this page tells the app which ones to use.
class AdminPricingScreen extends StatefulWidget {
  const AdminPricingScreen({super.key});
  @override
  State<AdminPricingScreen> createState() => _AdminPricingScreenState();
}

class _AdminPricingScreenState extends State<AdminPricingScreen> {
  final _supabase = SupabaseService();
  Map<String, dynamic>? _data;
  String? _error;
  final _search = TextEditingController();
  String _onlyGroup = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final d = await _supabase.adminPricing();
      if (!mounted) return;
      setState(() {
        _data = d;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _apply(Map<String, dynamic> d) {
    if (d.isNotEmpty) setState(() => _data = d);
  }

  void _snack(String text, {bool bad = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(text), backgroundColor: bad ? Brand.red : null));
  }

  List<Map<String, dynamic>> get _groups => [
        for (final g in (_data?['groups'] as List? ?? const []))
          Map<String, dynamic>.from(g as Map)
      ];

  List<Map<String, dynamic>> get _countries => [
        for (final c in (_data?['countries'] as List? ?? const []))
          Map<String, dynamic>.from(c as Map)
      ];

  // ------------------------------------------------------------ groups

  Future<void> _editGroup(Map<String, dynamic> g) async {
    final monthly =
        TextEditingController(text: '${g['monthly_eur'] ?? ''}');
    final yearly = TextEditingController(text: '${g['yearly_eur'] ?? ''}');
    final pm = TextEditingController(text: '${g['stripe_price_monthly'] ?? ''}');
    final py = TextEditingController(text: '${g['stripe_price_yearly'] ?? ''}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Group ${g['code']}: ${g['name']}'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                      'The euro prices are what the page shows until Stripe '
                      'has the prices. The Stripe price ids (price_...) are '
                      'from the Stripe dashboard, one monthly and one yearly, '
                      'each with the other currencies as currency options. '
                      'The hourly Stripe check then reads every amount.',
                      style: TextStyle(
                          fontSize: 12.5, height: 1.45, color: Brand.inkSecondary)),
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(
                      child: TextField(
                          controller: monthly,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          decoration:
                              const InputDecoration(labelText: 'Monthly, EUR')),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                          controller: yearly,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          decoration:
                              const InputDecoration(labelText: 'Yearly, EUR')),
                    ),
                  ]),
                  const SizedBox(height: 10),
                  TextField(
                      controller: pm,
                      decoration: const InputDecoration(
                          labelText: 'Stripe price id, monthly',
                          hintText: 'price_...')),
                  const SizedBox(height: 10),
                  TextField(
                      controller: py,
                      decoration: const InputDecoration(
                          labelText: 'Stripe price id, yearly',
                          hintText: 'price_...')),
                ]),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final d = await _supabase.setPricingGroup(
          '${g['code']}',
          num.tryParse(monthly.text.trim().replaceAll(',', '.')) ?? 0,
          num.tryParse(yearly.text.trim().replaceAll(',', '.')) ?? 0,
          pm.text.trim(),
          py.text.trim());
      if (!mounted) return;
      _apply(d);
      _snack('Group ${g['code']} saved. Stripe amounts refresh within the hour.');
    } catch (e) {
      if (mounted) _snack('That did not save: $e', bad: true);
    }
  }

  Widget _groupCard(Map<String, dynamic> g) {
    final amounts = Map<String, dynamic>.from(g['amounts'] as Map? ?? {});
    final mon = Map<String, dynamic>.from(amounts['monthly'] as Map? ?? {});
    final yr = Map<String, dynamic>.from(amounts['yearly'] as Map? ?? {});
    final ready = '${g['stripe_price_monthly'] ?? ''}'.isNotEmpty &&
        '${g['stripe_price_yearly'] ?? ''}'.isNotEmpty;
    final at = DateTime.tryParse('${g['amounts_at'] ?? ''}');
    final currencies = {...mon.keys, ...yr.keys}.toList()..sort();
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 1.5,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        onTap: () => _editGroup(g),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(
                width: 30,
                height: 30,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                    color: Brand.ink, borderRadius: BorderRadius.circular(8)),
                child: Text('${g['code']}',
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w800)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text('${g['name']}',
                    style: const TextStyle(
                        fontSize: 15.5, fontWeight: FontWeight.w700)),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                    color: (ready ? Brand.success : Brand.goldTextDark)
                        .withValues(alpha: .10),
                    borderRadius: BorderRadius.circular(6)),
                child: Text(ready ? 'In Stripe' : 'No Stripe price yet',
                    style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: ready ? Brand.success : Brand.goldTextDark)),
              ),
            ]),
            const SizedBox(height: 10),
            Text(
                '€${g['monthly_eur']} a month  ·  €${g['yearly_eur']} a year'
                '  ·  ${g['spaces'] ?? 0} spaces, ${g['verified'] ?? 0} Verified',
                style: const TextStyle(fontSize: 13, color: Brand.inkSecondary)),
            if (currencies.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final c in currencies)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                        color: Brand.field,
                        borderRadius: BorderRadius.circular(6)),
                    child: Text(
                        '$c  ${mon[c] == null ? '?' : formatMoney(mon[c] as num, c)} / '
                        '${yr[c] == null ? '?' : formatMoney(yr[c] as num, c)}',
                        style: const TextStyle(
                            fontSize: 12.5, fontWeight: FontWeight.w600)),
                  ),
              ]),
              if (at != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                      'Amounts from Stripe, read ${DateFormat('d MMM, HH:mm').format(at.toLocal())}.',
                      style: const TextStyle(fontSize: 11.5, color: Brand.inkMuted)),
                ),
            ] else if (ready)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                    'Waiting for the hourly Stripe check to read the amounts.',
                    style: TextStyle(fontSize: 11.5, color: Brand.inkMuted)),
              ),
          ]),
        ),
      ),
    );
  }

  // --------------------------------------------------------- countries

  Future<void> _editCountry(Map<String, dynamic> c) async {
    var group = '${c['group']}';
    var currency = '${c['currency']}';
    var locked = c['locked'] == true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text('${c['name']}'),
          content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Price group',
                    style: TextStyle(fontSize: 12.5, color: Brand.inkSecondary)),
                const SizedBox(height: 6),
                SegmentedButton<String>(
                  segments: [
                    for (final g in _groups)
                      ButtonSegment(
                          value: '${g['code']}', label: Text('${g['code']}')),
                  ],
                  selected: {group},
                  onSelectionChanged: (s) => setD(() => group = s.first),
                ),
                const SizedBox(height: 14),
                const Text('Default currency',
                    style: TextStyle(fontSize: 12.5, color: Brand.inkSecondary)),
                const SizedBox(height: 6),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'EUR', label: Text('EUR')),
                    ButtonSegment(value: 'GBP', label: Text('GBP')),
                    ButtonSegment(value: 'USD', label: Text('USD')),
                    ButtonSegment(value: 'AUD', label: Text('AUD')),
                  ],
                  selected: {currency},
                  onSelectionChanged: (s) => setD(() => currency = s.first),
                ),
                CheckboxListTile(
                  value: locked,
                  onChanged: (v) => setD(() => locked = v ?? false),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text('Only this currency, no toggle',
                      style: TextStyle(fontSize: 13.5)),
                ),
              ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Save')),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final d = await _supabase.setPricingCountry('${c['iso']}',
          group: group, currency: currency, locked: locked);
      if (!mounted) return;
      _apply(d);
      _snack('${c['name']}: group $group, $currency.');
    } catch (e) {
      if (mounted) _snack('That did not save: $e', bad: true);
    }
  }

  Future<void> _mapUnknown(String name) async {
    final q = TextEditingController();
    Map<String, dynamic>? picked;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) {
          final hits = _countries
              .where((c) => '${c['name']}'
                  .toLowerCase()
                  .contains(q.text.trim().toLowerCase()))
              .take(8)
              .toList();
          return AlertDialog(
            title: Text('"$name" is which country?'),
            content: SizedBox(
              width: 380,
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                        controller: q,
                        autofocus: true,
                        onChanged: (_) => setD(() {}),
                        decoration: const InputDecoration(
                            labelText: 'Country', prefixIcon: Icon(Icons.search))),
                    const SizedBox(height: 6),
                    for (final c in hits)
                      ListTile(
                        dense: true,
                        selected: picked?['iso'] == c['iso'],
                        title: Text('${c['name']}'),
                        subtitle: Text('Group ${c['group']}  ·  ${c['currency']}'),
                        onTap: () => setD(() => picked = c),
                      ),
                  ]),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel')),
              FilledButton(
                  onPressed:
                      picked == null ? null : () => Navigator.pop(ctx, true),
                  child: const Text('Map it')),
            ],
          );
        },
      ),
    );
    if (ok != true || picked == null || !mounted) return;
    try {
      final d = await _supabase.addPricingAlias(name, '${picked!['iso']}');
      if (!mounted) return;
      _apply(d);
      _snack('"$name" now counts as ${picked!['name']}.');
    } catch (e) {
      if (mounted) _snack('That did not save: $e', bad: true);
    }
  }

  // ------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final d = _data;
    final unmapped = [
      for (final u in (d?['unmapped'] as List? ?? const []))
        Map<String, dynamic>.from(u as Map)
    ];
    final q = _search.text.trim().toLowerCase();
    final countries = _countries
        .where((c) =>
            (_onlyGroup.isEmpty || '${c['group']}' == _onlyGroup) &&
            (q.isEmpty || '${c['name']}'.toLowerCase().contains(q)))
        .toList();
    final stripe = d?['stripe_connected'] == true;

    return Scaffold(
      appBar: AppBar(title: const Text('Pricing')),
      body: d == null && _error == null
          ? const Center(child: CircularProgressIndicator(color: Brand.red))
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_error!, style: const TextStyle(color: Brand.red)),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 760),
                      child: ListView(
                          padding: const EdgeInsets.fromLTRB(14, 12, 14, 40),
                          children: [
                            const Text(
                                'Verified is priced by the space\'s country: '
                                'four groups, monthly or yearly, in the '
                                'country\'s currency with a toggle to the '
                                'others. The prices themselves live in Stripe; '
                                'this page says which ones the app uses and '
                                'which group each country is in.',
                                style: TextStyle(
                                    fontSize: 13,
                                    height: 1.45,
                                    color: Brand.inkSecondary)),
                            if (!stripe)
                              Padding(
                                padding: const EdgeInsets.only(top: 10),
                                child: Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                      color: Brand.goldTint,
                                      borderRadius: BorderRadius.circular(8)),
                                  child: const Text(
                                      'Stripe is not connected from the database '
                                      '(no stripe_billing_key in the Vault), so '
                                      'Checkout cannot start. The claim form uses '
                                      'today\'s payment link until it is.',
                                      style: TextStyle(
                                          fontSize: 12.5,
                                          height: 1.45,
                                          color: Brand.goldTextDark)),
                                ),
                              ),
                            const SizedBox(height: 16),
                            const Text('GROUPS',
                                style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: .8,
                                    color: Brand.inkMuted)),
                            const SizedBox(height: 8),
                            for (final g in _groups) _groupCard(g),
                            if (unmapped.isNotEmpty) ...[
                              const SizedBox(height: 14),
                              const Text('COUNTRY NAMES NOT RECOGNISED',
                                  style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: .8,
                                      color: Brand.inkMuted)),
                              const SizedBox(height: 4),
                              const Text(
                                  'Spaces in these are priced as group B until '
                                  'you say which country they mean.',
                                  style: TextStyle(
                                      fontSize: 12.5, color: Brand.inkSecondary)),
                              const SizedBox(height: 6),
                              for (final u in unmapped)
                                ListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  leading: const Icon(Icons.help_outline,
                                      color: Brand.goldTextDark),
                                  title: Text('${u['country']}'),
                                  subtitle: Text(
                                      '${u['spaces']} space${u['spaces'] == 1 ? '' : 's'}'),
                                  trailing: TextButton(
                                      onPressed: () => _mapUnknown('${u['country']}'),
                                      child: const Text('Map')),
                                ),
                            ],
                            const SizedBox(height: 14),
                            const Text('COUNTRIES',
                                style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: .8,
                                    color: Brand.inkMuted)),
                            const SizedBox(height: 8),
                            Row(children: [
                              Expanded(
                                child: TextField(
                                    controller: _search,
                                    onChanged: (_) => setState(() {}),
                                    decoration: const InputDecoration(
                                        hintText: 'Find a country',
                                        prefixIcon: Icon(Icons.search),
                                        isDense: true)),
                              ),
                              const SizedBox(width: 8),
                              for (final code in ['', 'A', 'B', 'C', 'D'])
                                Padding(
                                  padding: const EdgeInsets.only(left: 4),
                                  child: ChoiceChip(
                                    label: Text(code.isEmpty ? 'All' : code),
                                    selected: _onlyGroup == code,
                                    showCheckmark: false,
                                    visualDensity: VisualDensity.compact,
                                    onSelected: (_) =>
                                        setState(() => _onlyGroup = code),
                                  ),
                                ),
                            ]),
                            const SizedBox(height: 6),
                            for (final c in countries)
                              ListTile(
                                dense: true,
                                contentPadding:
                                    const EdgeInsets.symmetric(horizontal: 4),
                                leading: Container(
                                  width: 26,
                                  height: 26,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                      color: Brand.field,
                                      borderRadius: BorderRadius.circular(6)),
                                  child: Text('${c['group']}',
                                      style: const TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w800)),
                                ),
                                title: Text('${c['name']}',
                                    style: const TextStyle(fontSize: 13.5)),
                                subtitle: Text(
                                    '${c['currency']}${c['locked'] == true ? ' only' : ''}'
                                    '${(c['spaces'] ?? 0) > 0 ? '  ·  ${c['spaces']} space${c['spaces'] == 1 ? '' : 's'}' : ''}',
                                    style: const TextStyle(fontSize: 12)),
                                trailing: const Icon(Icons.chevron_right,
                                    color: Brand.inkMuted),
                                onTap: () => _editCountry(c),
                              ),
                          ]),
                    ),
                  ),
                ),
    );
  }
}
