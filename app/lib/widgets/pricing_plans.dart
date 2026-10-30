import 'package:flutter/material.dart';

import '../theme.dart';
import 'motion.dart';
import 'pricing_picker.dart';
import 'ui.dart' show PlanFeatureRow;

/// Free and Premium side by side (Premium first on a phone), the way
/// the pricing page showed them: the price speaks first, more room
/// between the plans than inside them, Premium is the one to pick (red
/// border, the MAKE THE MOST OF NOMADWISE pill, the only filled button)
/// and sits raised, Yearly shows the twelve monthly payments struck
/// through. Used by step two of the claim page (Jonathan, 30 Oct 2026:
/// find your space first, then the pricing page).
class PricingPlans extends StatelessWidget {
  /// The prices for the space's country; null while they load.
  final PricingChoice? pricing;
  final bool wide;

  /// Shown in the price's place while [pricing] is null.
  final String waiting;
  final VoidCallback? onFree;
  final VoidCallback? onPremium;

  const PricingPlans({
    super.key,
    required this.pricing,
    required this.wide,
    required this.onFree,
    required this.onPremium,
    this.waiting = 'One moment',
  });

  @override
  Widget build(BuildContext context) {
    final free = _freeCard();
    final premium = _premiumCard(context);
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
            child:
                Padding(padding: const EdgeInsets.only(top: 10), child: free)),
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

  Widget _bigPrice(String amount, {String? unit, String? was}) {
    final size = wide ? 44.0 : 52.0;
    return Wrap(
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
                  style:
                      const TextStyle(fontSize: 16, color: Brand.inkSecondary)),
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
  }

  Widget _freeCard() => Container(
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
              child: _bigPrice(pricing == null
                  ? 'Free'
                  : formatMoney(0, pricing!.currency))),
          const SizedBox(height: 6),
          const Text('Where every space starts. No card needed.',
              style: TextStyle(fontSize: 14, color: Brand.inkSecondary)),
          SizedBox(height: wide ? 14 : 18),
          OutlinedButton(
            onPressed: onFree,
            style: OutlinedButton.styleFrom(
                minimumSize: Size.fromHeight(wide ? 44 : 48),
                foregroundColor: Brand.ink,
                side: const BorderSide(color: Brand.ink, width: 1.5),
                textStyle:
                    const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
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

  Widget _premiumCard(BuildContext context) {
    final p = pricing;
    final yearly = p?.period != 'monthly';
    Widget price;
    if (p == null || p.chosen == null) {
      price = Column(
          key: const ValueKey('none'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: wide ? 44 : 52,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(waiting,
                    style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: Brand.inkMuted)),
              ),
            ),
            const SizedBox(height: 6),
            const Text('Monthly or yearly. Cancel any time.',
                style: TextStyle(fontSize: 14, color: Brand.inkSecondary)),
          ]);
    } else {
      final m = p.monthly ?? 0;
      final y = p.yearly ?? 0;
      price = Column(
          key: ValueKey('${p.period}-${p.currency}'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _bigPrice(formatMoney(yearly ? y : m, p.currency),
                unit: yearly ? '/year' : '/month',
                was: yearly && m * 12 > y
                    ? formatMoney(m * 12, p.currency)
                    : null),
            const SizedBox(height: 6),
            Text(
                yearly
                    ? 'Works out at ${formatMoney((y / 12).round(), p.currency)} a '
                        'month, billed once a year.'
                    : 'Billed every month. Cancel any time.',
                style: const TextStyle(fontSize: 14, color: Brand.inkSecondary)),
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
            onPressed: onPremium,
            style: FilledButton.styleFrom(
                minimumSize: Size.fromHeight(wide ? 44 : 48),
                backgroundColor: Brand.red,
                textStyle:
                    const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
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
