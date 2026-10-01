import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/supabase_service.dart';
import '../theme.dart';
import 'pricing_picker.dart';
import 'ui.dart';

/// Owner account, "Plan & billing": the owner runs their own plan.
/// Their plan and its status, the next payment, the card on file, every
/// invoice to view or download, switching down to Free (cancel renewal,
/// with an optional reason) and back, and Stripe's secure page for the
/// card and billing details, opened straight at the right step. Read
/// live from Stripe (migration 107). Until billing is connected, the
/// plan shows from our own records with a way to reach us.
class BillingPanel extends StatefulWidget {
  final String venueId;
  final String venueName;
  final bool preview;
  // In a founder's preview: the plan being previewed, not the real one.
  final String? tierOverride;
  final VoidCallback onGoVerified;

  /// The space's country, for what Verified would cost (migration 115).
  final String? country;
  const BillingPanel({
    super.key,
    required this.venueId,
    required this.venueName,
    required this.onGoVerified,
    this.preview = false,
    this.tierOverride,
    this.country,
  });
  @override
  State<BillingPanel> createState() => _BillingPanelState();
}

class _BillingPanelState extends State<BillingPanel> {
  final _supabase = SupabaseService();
  PricingChoice? _pricing;
  Map<String, dynamic>? _b;
  String? _error;
  String? _busy; // which action is running

  static const _benefits = [
    'The green Verified badge on your page and in every list',
    'Always shown above free spaces in your city and area',
    'A "Send an enquiry" button that emails you directly, no commission',
    'Your event or offer in the advert slot on your page',
  ];
  static const _freeGets = [
    'Your page on Nomadwise, found by Google and AI assistants',
    'Your own description, photos, prices and hours',
    'Your Owner account to keep it up to date',
  ];

  @override
  void initState() {
    super.initState();
    _load();
    _supabase.pricingFor(widget.country).then((p) {
      if (mounted && p != null) setState(() => _pricing = PricingChoice(p));
    });
  }

  Future<void> _load() async {
    try {
      final b = await _supabase.ownerBilling(widget.venueId);
      if (mounted) {
        setState(() {
          _b = b;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _b = {};
          _error = '$e'.contains('owner_billing')
              ? null // not installed yet: fall back quietly
              : 'Could not load your billing just now. Please try again.';
        });
      }
    }
  }

  // ---- helpers ----
  static String _money(num? cents, String? currency) {
    if (cents == null) return '';
    final c = (currency ?? 'EUR').toUpperCase();
    final v = cents / 100;
    final amount = v == v.roundToDouble()
        ? NumberFormat('#,##0').format(v)
        : NumberFormat('#,##0.00').format(v);
    const sym = {'EUR': '€', 'GBP': '£', 'USD': '\$'};
    return sym.containsKey(c) ? '${sym[c]}$amount' : '$amount $c';
  }

  static String _day(dynamic iso) {
    final d = DateTime.tryParse('${iso ?? ''}');
    return d == null ? '' : DateFormat('d MMMM yyyy').format(d.toLocal());
  }

  static String _brand(String? b) => switch ((b ?? '').toLowerCase()) {
        'visa' => 'Visa',
        'mastercard' => 'Mastercard',
        'amex' => 'American Express',
        'discover' => 'Discover',
        'jcb' => 'JCB',
        'unionpay' => 'UnionPay',
        '' => 'Card',
        final x => x[0].toUpperCase() + x.substring(1),
      };

  void _say(String text, {bool bad = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(text), backgroundColor: bad ? Brand.red : null));
  }

  Future<void> _portal(String flow) async {
    if (widget.preview) {
      _say('Preview: this would open Stripe\'s secure billing page.');
      return;
    }
    setState(() => _busy = flow);
    try {
      final url = await _supabase.ownerBillingPortal(widget.venueId, flow);
      if (url != null) {
        await launchUrl(Uri.parse(url), webOnlyWindowName: '_self');
      }
    } catch (e) {
      _say('That did not open. Please try again in a moment.', bad: true);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _action(String action, {String? reason}) async {
    if (widget.preview) {
      _say('Preview: nothing changes.');
      return;
    }
    setState(() => _busy = action);
    try {
      await _supabase.ownerBillingAction(widget.venueId, action,
          reason: reason);
      await _load();
      if (mounted) {
        _say(action == 'cancel'
            ? 'Done. Your renewal is off; you stay Verified until the end of your paid year.'
            : 'Welcome back! Your Verified plan will renew as before.');
      }
    } catch (e) {
      _say('That did not go through. Please try again.', bad: true);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _confirmCancel(String until) async {
    final reasons = [
      'It costs too much for us',
      'Not enough enquiries yet',
      'We are closing or moving',
      'We only wanted to try it',
      'Something else',
    ];
    String? picked;
    final other = TextEditingController();
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          title: const Text('Switch to the free plan?'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                        'Your Verified plan will not renew. You stay Verified '
                        'until $until; after that your page stays on Nomadwise '
                        'as a free listing, with your description, photos and '
                        'details.',
                        style: const TextStyle(fontSize: 14, height: 1.5)),
                    const SizedBox(height: 12),
                    const Text('From then on your page would not have:',
                        style: TextStyle(
                            fontSize: 13, color: Brand.inkSecondary)),
                    const SizedBox(height: 6),
                    for (final b in _benefits)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(Icons.remove,
                                  size: 16, color: Brand.inkMuted),
                              const SizedBox(width: 8),
                              Expanded(
                                  child: Text(b,
                                      style: const TextStyle(
                                          fontSize: 13,
                                          color: Brand.inkSecondary))),
                            ]),
                      ),
                    const SizedBox(height: 16),
                    const Text('Would you tell us why? (optional)',
                        style: TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 13.5)),
                    const SizedBox(height: 8),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      for (final r in reasons)
                        ChoiceChip(
                          label: Text(r),
                          selected: picked == r,
                          showCheckmark: false,
                          selectedColor: Brand.logoTealTint,
                          onSelected: (on) => set(() => picked = on ? r : null),
                        ),
                    ]),
                    if (picked == 'Something else') ...[
                      const SizedBox(height: 10),
                      TextField(
                        controller: other,
                        minLines: 2,
                        maxLines: 4,
                        decoration: const InputDecoration(
                            labelText: 'Tell us more',
                            border: OutlineInputBorder()),
                      ),
                    ],
                  ]),
            ),
          ),
          actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: TextButton.styleFrom(foregroundColor: Brand.inkSecondary),
                child: const Text('Switch to free')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, false),
                style: FilledButton.styleFrom(backgroundColor: Brand.red),
                child: const Text('Keep Verified')),
          ],
        ),
      ),
    );
    final reason = picked == 'Something else'
        ? (other.text.trim().isEmpty ? 'Something else' : other.text.trim())
        : picked;
    other.dispose();
    if (go == true) await _action('cancel', reason: reason);
  }

  // ---- building blocks ----
  Widget _card({required Widget child, Color? border}) => Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 14),
        padding: EdgeInsets.all(
            MediaQuery.sizeOf(context).width < 600 ? 16 : 20),
        decoration: BoxDecoration(
          color: Brand.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: border ?? Brand.border),
        ),
        child: child,
      );

  Widget _title(String t, {String? sub}) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t,
              style:
                  const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
          if (sub != null) ...[
            const SizedBox(height: 3),
            Text(sub,
                style: const TextStyle(
                    fontSize: 12.5, height: 1.4, color: Brand.inkMuted)),
          ],
        ]),
      );

  Widget _pill(String t, Color bg, Color fg) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        decoration:
            BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
        child: Text(t,
            style: TextStyle(
                fontSize: 11.5, fontWeight: FontWeight.w800, color: fg)),
      );

  Widget _spin() => const SizedBox(
      width: 16,
      height: 16,
      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white));

  @override
  Widget build(BuildContext context) {
    final b = _b;
    if (b == null) {
      return _card(
          child: const Padding(
        padding: EdgeInsets.all(30),
        child: Center(child: CircularProgressIndicator(color: Brand.red)),
      ));
    }
    final tier = widget.tierOverride ?? '${b['tier'] ?? 'free'}';
    final verified = tier == 'verified';
    final connected = b['connected'] == true;
    final sub = b['subscription'] is Map
        ? Map<String, dynamic>.from(b['subscription'] as Map)
        : null;
    final card = b['card'] is Map
        ? Map<String, dynamic>.from(b['card'] as Map)
        : null;
    final invoices = List<Map<String, dynamic>>.from(
        ((b['invoices'] ?? const []) as List)
            .map((x) => Map<String, dynamic>.from(x as Map)));
    final ending = sub?['cancel_at_period_end'] == true;
    final status = '${sub?['status'] ?? ''}';
    final trouble = status == 'past_due' || status == 'unpaid';
    final periodEnd = _day(sub?['current_period_end'] ?? b['renews_at']);
    final price = sub == null
        ? (_pricing?.fromWords.isNotEmpty == true
            ? _pricing!.fromWords
            : '€99 a year')
        : '${_money(sub['amount'] as num?, '${sub['currency']}')} a '
            '${sub['interval'] ?? 'year'}';

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text(_error!, style: const TextStyle(color: Brand.red)),
        ),

      // ---- your plan ----
      _card(
        border: trouble
            ? Brand.red
            : ending
                ? Brand.goldTextDark
                : null,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Text('Your plan',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            const Spacer(),
            if (verified)
              trouble
                  ? _pill('Payment problem', Brand.accentTint, Brand.red)
                  : ending
                      ? _pill('Ends $periodEnd', Brand.goldTint,
                          Brand.goldTextDark)
                      : _pill('Active', Brand.successTint, Brand.success)
            else
              _pill('Free', Brand.field, Brand.inkSecondary),
          ]),
          const SizedBox(height: 12),
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(verified ? 'Verified' : 'Free listing',
                style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 26,
                    letterSpacing: -0.4)),
            if (verified) ...[
              const SizedBox(width: 8),
              const Padding(
                padding: EdgeInsets.only(bottom: 4),
                child: Icon(Icons.verified, color: Brand.success, size: 22),
              ),
              const SizedBox(width: 10),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(price,
                    style: const TextStyle(
                        fontSize: 14, color: Brand.inkSecondary)),
              ),
            ],
          ]),
          const SizedBox(height: 8),
          Text(
              !verified
                  ? 'Your page is on Nomadwise for free, and stays free.'
                  : trouble
                      ? 'Your last payment did not go through. Update your '
                          'card to keep Verified.'
                      : ending
                          ? 'You stay Verified until $periodEnd. After that '
                              'your page stays on Nomadwise as a free listing.'
                          : periodEnd.isEmpty
                              ? 'Verified is on.'
                              : 'Renews on $periodEnd'
                                  '${sub != null ? ' for ${_money(sub['amount'] as num?, '${sub['currency']}')}' : ''}.'
                                  ' Change or stop it any time here.',
              style: const TextStyle(fontSize: 14, height: 1.5)),
          const SizedBox(height: 14),
          Wrap(spacing: 10, runSpacing: 10, children: [
            if (!verified)
              FilledButton(
                  onPressed: widget.onGoVerified,
                  style: FilledButton.styleFrom(backgroundColor: Brand.red),
                  child: const Text('Go Verified')),
            if (verified && trouble && connected)
              FilledButton.icon(
                  onPressed: _busy != null ? null : () => _portal('card'),
                  style: FilledButton.styleFrom(backgroundColor: Brand.red),
                  icon: _busy == 'card'
                      ? _spin()
                      : const Icon(Icons.credit_card, size: 18),
                  label: const Text('Update card')),
            if (verified && ending && connected)
              FilledButton(
                  onPressed: _busy != null ? null : () => _action('resume'),
                  style: FilledButton.styleFrom(backgroundColor: Brand.red),
                  child: _busy == 'resume'
                      ? _spin()
                      : const Text('Keep Verified')),
          ]),
        ]),
      ),

      // ---- plans side by side ----
      _card(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _title('Plans',
              sub: 'Move between them whenever you like. Going down to free '
                  'keeps Verified until the end of the period you paid for.'),
          LayoutBuilder(builder: (context, box) {
            final two = box.maxWidth >= 560;
            final free = _planBox(
              name: 'Free',
              price: '€0',
              per: 'always',
              lines: _freeGets,
              current: !verified || ending,
              currentLabel: ending ? 'From $periodEnd' : 'Current plan',
              action: verified && !ending && connected
                  ? TextButton(
                      onPressed: _busy != null
                          ? null
                          : () => _confirmCancel(periodEnd),
                      style: TextButton.styleFrom(
                          foregroundColor: Brand.inkSecondary),
                      child: _busy == 'cancel'
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Text('Switch to free'))
                  : null,
            );
            final paid = _planBox(
              name: 'Verified',
              price: sub == null
                  ? (_pricing?.monthly != null
                      ? formatMoney(_pricing!.monthly!, _pricing!.currency)
                      : '€99')
                  : _money(sub['amount'] as num?, '${sub['currency']}'),
              per: sub == null
                  ? (_pricing?.yearly != null
                      ? 'a month, or ${formatMoney(_pricing!.yearly!, _pricing!.currency)} a year'
                      : 'a year')
                  : 'a ${sub['interval'] ?? 'year'}',
              lines: _benefits,
              plus: true,
              current: verified,
              currentLabel: ending ? 'Until $periodEnd' : 'Current plan',
              action: !verified
                  ? FilledButton(
                      onPressed: widget.onGoVerified,
                      style: FilledButton.styleFrom(backgroundColor: Brand.red),
                      child: const Text('Go Verified'))
                  : ending && connected
                      ? FilledButton(
                          onPressed:
                              _busy != null ? null : () => _action('resume'),
                          style: FilledButton.styleFrom(
                              backgroundColor: Brand.red),
                          child: const Text('Keep Verified'))
                      : null,
            );
            return two
                ? IntrinsicHeight(
                    child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(child: free),
                          const SizedBox(width: 12),
                          Expanded(child: paid),
                        ]))
                : Column(children: [free, const SizedBox(height: 12), paid]);
          }),
        ]),
      ),

      if (verified && connected) ...[
        // ---- payment method and billing details ----
        _card(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _title('Payment method and billing details'),
            Row(children: [
              Container(
                width: 46,
                height: 32,
                decoration: BoxDecoration(
                  color: Brand.bg,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Brand.border),
                ),
                child: const Icon(Icons.credit_card,
                    size: 18, color: Brand.inkSecondary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                    card == null
                        ? 'No card on file'
                        : card['last4'] == null
                            ? _brand('${card['type']}')
                            : '${_brand('${card['brand']}')} ending ${card['last4']}'
                                '${card['exp_month'] != null ? '  ·  expires ${card['exp_month'].toString().padLeft(2, '0')}/${'${card['exp_year']}'.substring('${card['exp_year']}'.length - 2)}' : ''}',
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600)),
              ),
            ]),
            if ('${b['email'] ?? ''}'.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text('Receipts go to ${b['email']}',
                  style: const TextStyle(
                      fontSize: 13, color: Brand.inkSecondary)),
            ],
            const SizedBox(height: 14),
            Wrap(spacing: 10, runSpacing: 10, children: [
              OutlinedButton.icon(
                  onPressed: _busy != null ? null : () => _portal('card'),
                  icon: _busy == 'card'
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.credit_card, size: 18),
                  label: const Text('Update card')),
              OutlinedButton.icon(
                  onPressed: _busy != null ? null : () => _portal('home'),
                  icon: _busy == 'home'
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.receipt_long_outlined, size: 18),
                  label: const Text('Billing name, address and tax ID')),
            ]),
            const SizedBox(height: 10),
            const Row(children: [
              Icon(Icons.lock_outline, size: 14, color: Brand.inkMuted),
              SizedBox(width: 6),
              Expanded(
                child: Text(
                    'Card details are handled by Stripe and never touch our '
                    'servers.',
                    style: TextStyle(fontSize: 12, color: Brand.inkMuted)),
              ),
            ]),
          ]),
        ),

        // ---- invoices ----
        _card(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _title('Invoices and receipts',
                sub: 'Every payment, ready to view or download for your '
                    'accounts.'),
            if (invoices.isEmpty)
              const Text('No invoices yet.',
                  style: TextStyle(color: Brand.inkMuted, fontSize: 13))
            else
              for (var i = 0; i < invoices.length; i++) _invoiceRow(invoices[i], i),
          ]),
        ),
      ],

      if (verified && !connected)
        _card(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _title('Card, invoices and receipts'),
            const Text(
                'Your card, invoices and receipts will show here. We are '
                'switching this on; until then, reply to your payment '
                'receipt email or write to us and we sort anything out for '
                'you.',
                style: TextStyle(fontSize: 13.5, height: 1.5)),
            const SizedBox(height: 12),
            OutlinedButton.icon(
                onPressed: () => launchUrl(Uri.parse(
                    'mailto:hello@nomadwise.io?subject='
                    '${Uri.encodeComponent('Billing: ${widget.venueName}')}')),
                icon: const Icon(Icons.mail_outline, size: 18),
                label: const Text('Email hello@nomadwise.io')),
          ]),
        ),

      const Padding(
        padding: EdgeInsets.fromLTRB(4, 2, 4, 0),
        child: Text(
            'Questions about billing? hello@nomadwise.io, we are happy to help.',
            style: TextStyle(fontSize: 12, color: Brand.inkMuted)),
      ),
    ]);
  }

  Widget _planBox({
    required String name,
    required String price,
    required String per,
    required List<String> lines,
    required bool current,
    required String currentLabel,
    bool plus = false,
    Widget? action,
  }) =>
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: current ? Brand.bg : Brand.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: current ? Brand.ink : Brand.border, width: current ? 1.6 : 1),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(name,
                style:
                    const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            const Spacer(),
            if (current) _pill(currentLabel, Brand.ink, Colors.white),
          ]),
          const SizedBox(height: 8),
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(price,
                style: const TextStyle(
                    fontWeight: FontWeight.w800, fontSize: 24, height: 1)),
            const SizedBox(width: 6),
            Text(per,
                style: const TextStyle(fontSize: 13, color: Brand.inkSecondary)),
          ]),
          const SizedBox(height: 12),
          if (plus)
            const Padding(
              padding: EdgeInsets.only(bottom: 6),
              child: Text('Everything in Free, plus:',
                  style: TextStyle(fontSize: 12.5, color: Brand.inkSecondary)),
            ),
          for (final l in lines)
            PlanFeatureRow(l, extra: plus, fontSize: 13.5),
          if (action != null) ...[const SizedBox(height: 8), action],
        ]),
      );

  Widget _invoiceRow(Map<String, dynamic> inv, int i) {
    final status = '${inv['status'] ?? ''}';
    final paid = status == 'paid';
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        border: i == 0
            ? null
            : const Border(top: BorderSide(color: Brand.hairline)),
      ),
      child: Row(children: [
        Expanded(
          flex: 3,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_day(inv['date']),
                style:
                    const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
            if ('${inv['number'] ?? ''}'.isNotEmpty)
              Text('${inv['number']}',
                  style: const TextStyle(fontSize: 11.5, color: Brand.inkMuted)),
          ]),
        ),
        Expanded(
          flex: 2,
          child: Text(_money(inv['amount'] as num?, '${inv['currency']}'),
              style: const TextStyle(fontSize: 13.5)),
        ),
        _pill(paid ? 'Paid' : status == 'open' ? 'Due' : 'Unpaid',
            paid ? Brand.successTint : Brand.accentTint,
            paid ? Brand.success : Brand.red),
        const SizedBox(width: 8),
        if ('${inv['view'] ?? ''}'.startsWith('http'))
          TextButton(
              onPressed: () => launchUrl(Uri.parse('${inv['view']}'),
                  mode: LaunchMode.externalApplication),
              child: const Text('View')),
        if ('${inv['pdf'] ?? ''}'.startsWith('http'))
          IconButton(
              tooltip: 'Download PDF',
              onPressed: () => launchUrl(Uri.parse('${inv['pdf']}'),
                  mode: LaunchMode.externalApplication),
              icon: const Icon(Icons.download_outlined, size: 20)),
      ]),
    );
  }
}
