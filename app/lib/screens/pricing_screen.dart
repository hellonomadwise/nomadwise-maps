import 'package:flutter/material.dart';

import '../services/analytics_service.dart';
import '../services/supabase_service.dart';
import '../theme.dart';
import '../widgets/motion.dart';
import '../widgets/pricing_picker.dart';
import '../widgets/ui.dart' show PlanFeatureRow;
import 'claim_screen.dart';
import 'owner_screen.dart';

/// The pricing page for spaces (nomadmaps.io/pricing, CR "Public
/// pricing page", Jonathan 30 Oct 2026): Free and Premium side by side
/// for anyone, before claiming. Prices depend on the country, so the
/// page asks "Where is your space?" first and shows the Premium price
/// only once a country is chosen. Nothing is guessed from the device:
/// a VPN or a travelling owner would get the wrong price.
///
/// Laid out with the six pricing-table rules Jonathan shared: the price
/// speaks first, more room between plans than inside them, one plan to
/// pick (Premium: accent border, pill, the only filled button), the pick
/// raised, the yearly saving shown, and every tap answering at once.
/// The price paid is still the one for the country of the space
/// claimed; this page is a preview, and both buttons open the claim
/// page with the plan (and period and currency) already chosen.
class PricingScreen extends StatefulWidget {
  const PricingScreen({super.key});

  @override
  State<PricingScreen> createState() => _PricingScreenState();
}

/// Side by side above this, stacked below it (Premium first).
const double _wideAt = 860;

class _PricingScreenState extends State<PricingScreen> {
  final _supabase = SupabaseService();

  List<Map<String, dynamic>> _countries = const [];
  bool _countriesFailed = false;
  String? _country; // the country's name, as pricing_for() takes it
  PricingChoice? _pricing;
  bool _loadingPrice = false;
  bool _priceFailed = false;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    Analytics.capture('pricing_viewed');
    _supabase.pricingCountries().then((list) {
      if (!mounted) return;
      setState(() {
        _countries = list;
        _countriesFailed = list.isEmpty;
      });
    });
  }

  Future<void> _pickCountry(String? name) async {
    if (name == null || name == _country) return;
    final seq = ++_seq;
    final keep = _pricing?.period ?? 'yearly';
    setState(() {
      _country = name;
      _loadingPrice = true;
    });
    Analytics.capture('pricing_country', {'country': name});
    final p = await _supabase.pricingFor(name);
    if (!mounted || seq != _seq) return;
    setState(() {
      _loadingPrice = false;
      _priceFailed = p == null;
      // A failed load can be tried again by choosing the country again.
      if (p == null) _country = null;
      _pricing = p == null ? null : (PricingChoice(p)..period = keep);
    });
  }

  void _toClaim(String plan) {
    final p = _pricing;
    Analytics.capture('pricing_cta', {
      'plan': plan,
      'country': _country,
      'period': p?.period,
      'currency': p?.currency,
    });
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ClaimScreen(
              // Shown in Outreach: "after choosing Premium on the
              // pricing page".
              from: 'pricing_$plan',
              plan: plan,
              period: plan == 'premium' ? p?.period : null,
              currency: plan == 'premium' ? p?.currency : null,
            )));
  }

  // ---------------------------------------------------------- layout

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Brand.bg,
      body: SafeArea(
        child: LayoutBuilder(builder: (context, box) {
          final wide = box.maxWidth >= _wideAt;
          final side = wide ? 40.0 : 16.0;
          return Column(children: [
            _topBar(wide),
            Expanded(
              child: SingleChildScrollView(
                // Wide: everything fits above the fold on a laptop
                // (Jonathan, 30 Oct 2026: "it would be good if it could
                // all fit in top fold").
                padding: EdgeInsets.fromLTRB(side, wide ? 20 : 24, side, wide ? 20 : 40),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 940),
                    child: Column(
                        crossAxisAlignment: wide
                            ? CrossAxisAlignment.center
                            : CrossAxisAlignment.stretch,
                        children: [
                          _heading(wide),
                          SizedBox(height: wide ? 16 : 20),
                          _picker(wide),
                          SizedBox(height: wide ? 26 : 28),
                          _plans(wide),
                          SizedBox(height: wide ? 14 : 28),
                          Text(
                              'You pay the price for the country your space is '
                              'in. Already claimed your page? Get Premium from '
                              'your Owner account.',
                              textAlign:
                                  wide ? TextAlign.center : TextAlign.start,
                              style: const TextStyle(
                                  fontSize: 13,
                                  height: 1.5,
                                  color: Brand.inkSecondary)),
                        ]),
                  ),
                ),
              ),
            ),
          ]);
        }),
      ),
    );
  }

  Widget _topBar(bool wide) => Container(
        height: wide ? 52 : 56,
        padding: EdgeInsets.symmetric(horizontal: wide ? 40 : 16),
        decoration: const BoxDecoration(
            color: Brand.surface,
            border: Border(bottom: BorderSide(color: Brand.border))),
        child: Row(children: [
          // All one colour (Jonathan, 30 Oct 2026: the .io should not
          // be red).
          const Text('nomadwise.io',
              style: TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.3,
                  color: Brand.ink)),
          const SizedBox(width: 12),
          const Text('For spaces',
              style: TextStyle(fontSize: 14, color: Brand.inkSecondary)),
          const Spacer(),
          TextButton(
              onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const OwnerScreen())),
              child: Text(wide ? 'Sign in to your Owner account' : 'Sign in')),
        ]),
      );

  Widget _heading(bool wide) => Column(
          crossAxisAlignment:
              wide ? CrossAxisAlignment.center : CrossAxisAlignment.start,
          children: [
            Text('Free to be on Nomadwise. Premium to stand out.',
                textAlign: wide ? TextAlign.center : TextAlign.start,
                style: TextStyle(
                    fontSize: wide ? 32 : 27,
                    height: 1.2,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                    color: Brand.ink)),
            const SizedBox(height: 6),
            Text(
                'Claiming your page is free. Premium is optional, monthly or '
                'yearly, and you can cancel any time.',
                textAlign: wide ? TextAlign.center : TextAlign.start,
                style: const TextStyle(
                    fontSize: 15, height: 1.5, color: Brand.inkSecondary)),
          ]);

  /// "Where is your space?" first, then Monthly / Yearly (and the
  /// currency where the country offers more than one).
  Widget _picker(bool wide) {
    final p = _pricing;
    final dropdown = _countriesFailed
        ? const Text(
            'The list of countries did not load. Refresh the page to try '
            'again.',
            style: TextStyle(fontSize: 13.5, color: Brand.red))
        : LayoutBuilder(
            builder: (context, c) => DropdownMenu<String>(
                  width: wide ? 300 : c.maxWidth,
                  menuHeight: 360,
                  enableFilter: true,
                  requestFocusOnTap: true,
                  hintText: _countries.isEmpty ? 'Loading countries' : 'Choose a country',
                  leadingIcon: const Icon(Icons.public, size: 18),
                  dropdownMenuEntries: [
                    for (final c in _countries)
                      DropdownMenuEntry(
                          value: '${c['name']}', label: '${c['name']}'),
                  ],
                  onSelected: _pickCountry,
                ));
    const whereLabel = Text('Where is your space?',
        style: TextStyle(
            fontSize: 14, fontWeight: FontWeight.w700, color: Brand.ink));
    final where = wide
        ? Row(mainAxisSize: MainAxisSize.min, children: [
            whereLabel,
            const SizedBox(width: 12),
            dropdown,
          ])
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [whereLabel, const SizedBox(height: 8), dropdown]);
    final pay = p == null
        ? null
        : Wrap(
            spacing: 16,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
                PeriodToggle(
                    choice: p, onChanged: (c) => setState(() => _pricing = c)),
                CurrencyPicker(
                    choice: p, onChanged: (c) => setState(() => _pricing = c)),
              ]);
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: wide ? 16 : 18, vertical: wide ? 10 : 18),
      decoration: BoxDecoration(
          color: Brand.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Brand.border)),
      child: Wrap(
          spacing: 32,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [where, if (pay != null) pay]),
    );
  }

  Widget _plans(bool wide) {
    final free = _freeCard(wide);
    final premium = _premiumCard(wide);
    if (!wide) {
      // On a phone the main choice comes first.
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const SizedBox(height: 10),
        premium,
        const SizedBox(height: 24),
        free,
      ]);
    }
    return IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(
            child: Padding(
                padding: const EdgeInsets.only(top: 10), child: free)),
        const SizedBox(width: 32),
        // The pick, raised.
        Expanded(
            child: Transform.translate(
                offset: const Offset(0, -6), child: premium)),
      ]),
    );
  }

  Widget _planLabel(String text, {bool premium = false}) => Text(text,
      style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
          color: premium ? const Color(0xFFC42A33) : Brand.inkSecondary));

  Widget _bigPrice(String amount,
          {String? unit, String? was, double size = 52}) =>
      Wrap(
          crossAxisAlignment: WrapCrossAlignment.end,
          spacing: 8,
          children: [
            Text(amount,
                style: TextStyle(
                    fontSize: size,
                    height: 1,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -1,
                    color: Brand.ink)),
            if (unit != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(unit,
                    style: const TextStyle(
                        fontSize: 16, color: Brand.inkSecondary)),
              ),
            if (was != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(was,
                    style: const TextStyle(
                        fontSize: 16,
                        color: Brand.inkMuted,
                        decoration: TextDecoration.lineThrough)),
              ),
          ]);

  Widget _freeCard(bool wide) => Container(
        padding: EdgeInsets.all(wide ? 22 : 28),
        decoration: BoxDecoration(
            color: Brand.surface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Brand.border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _planLabel('FREE'),
          const SizedBox(height: 8),
          Align(
              alignment: Alignment.centerLeft,
              child: _bigPrice(
                  _pricing == null
                      ? 'Free'
                      : formatMoney(0, _pricing!.currency),
                  size: wide ? 44 : 52)),
          const SizedBox(height: 6),
          const Text('Where every space starts. No card needed.',
              style: TextStyle(fontSize: 14, color: Brand.inkSecondary)),
          SizedBox(height: wide ? 14 : 18),
          OutlinedButton(
            onPressed: () => _toClaim('free'),
            style: OutlinedButton.styleFrom(
                minimumSize: Size.fromHeight(wide ? 44 : 48),
                foregroundColor: Brand.ink,
                side: const BorderSide(color: Brand.ink, width: 1.5),
                textStyle: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w700)),
            child: const Text('Claim your page free'),
          ),
          SizedBox(height: wide ? 14 : 20),
          const Text('What you get:',
              style: TextStyle(
                  fontSize: 13.5, fontWeight: FontWeight.w700, color: Brand.ink)),
          SizedBox(height: wide ? 10 : 12),
          for (final t in planFreeGets)
            PlanFeatureRow(t, fontSize: wide ? 14 : 15),
        ]),
      );

  Widget _premiumCard(bool wide) {
    final p = _pricing;
    final yearly = p?.period != 'monthly';
    Widget price;
    if (p == null) {
      price = Column(
          key: const ValueKey('none'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: wide ? 44 : 52,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                    _loadingPrice
                        ? 'One moment'
                        : _priceFailed
                            ? 'The price did not load. Choose the country again.'
                            : 'Choose your country to see your price',
                    style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: Brand.inkMuted)),
              ),
            ),
            const SizedBox(height: 6),
            const Text('Prices are set per country, in your currency.',
                style: TextStyle(fontSize: 14, color: Brand.inkSecondary)),
          ]);
    } else {
      final m = p.monthly ?? 0;
      final y = p.yearly ?? 0;
      price = Column(
          key: ValueKey('${p.period}-${p.currency}-$_country'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _bigPrice(formatMoney(yearly ? y : m, p.currency),
                unit: yearly ? '/year' : '/month',
                was: yearly && m * 12 > y
                    ? formatMoney(m * 12, p.currency)
                    : null,
                size: wide ? 44 : 52),
            const SizedBox(height: 6),
            Text(
                yearly
                    ? 'Works out at ${formatMoney((y / 12).round(), p.currency)} a '
                        'month, billed once a year.'
                    : 'Billed every month. Cancel any time.',
                style:
                    const TextStyle(fontSize: 14, color: Brand.inkSecondary)),
          ]);
    }
    return Stack(clipBehavior: Clip.none, children: [
      Container(
        padding: wide
            ? const EdgeInsets.fromLTRB(22, 24, 22, 22)
            : const EdgeInsets.fromLTRB(28, 30, 28, 28),
        decoration: BoxDecoration(
            color: Brand.surface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Brand.red, width: 2),
            boxShadow: const [
              BoxShadow(
                  color: Color(0x24142032),
                  blurRadius: 48,
                  offset: Offset(0, 24)),
            ]),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            _planLabel('PREMIUM', premium: true),
            const SizedBox(width: 6),
            const Icon(Icons.verified, size: 16, color: Brand.success),
          ]),
          const SizedBox(height: 8),
          AnimatedSwitcher(
              duration: Motion.of(context, const Duration(milliseconds: 200)),
              switchInCurve: Curves.easeOut,
              switchOutCurve: Curves.easeOut,
              layoutBuilder: (cur, prev) => Stack(
                  alignment: Alignment.topLeft,
                  children: [...prev, if (cur != null) cur]),
              child: price),
          SizedBox(height: wide ? 14 : 18),
          FilledButton(
            onPressed: () => _toClaim('premium'),
            style: FilledButton.styleFrom(
                minimumSize: Size.fromHeight(wide ? 44 : 48),
                backgroundColor: Brand.red,
                textStyle: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w700)),
            child: const Text('Get Premium'),
          ),
          SizedBox(height: wide ? 14 : 20),
          const Text('Everything in Free, plus:',
              style: TextStyle(
                  fontSize: 13.5, fontWeight: FontWeight.w700, color: Brand.ink)),
          SizedBox(height: wide ? 10 : 12),
          for (final t in planPremiumAdds)
            PlanFeatureRow(t, extra: true, fontSize: wide ? 14 : 15),
        ]),
      ),
      Positioned(
        top: -12,
        left: 0,
        right: 0,
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(
                color: Brand.red, borderRadius: BorderRadius.circular(20)),
            child: const Text('MAKE THE MOST OF NOMADWISE',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1,
                    color: Colors.white)),
          ),
        ),
      ),
    ]);
  }
}
