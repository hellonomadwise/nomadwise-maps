import 'package:flutter/material.dart';

import '../theme.dart';

/// Money the way each currency writes it: "€10", "£8.50", "$17",
/// "A$25". Whole amounts drop the decimals.
String formatMoney(num minor, String currency) {
  final amount = minor / 100;
  final symbol = switch (currency) {
    'EUR' => '€',
    'GBP' => '£',
    'USD' => '\$',
    'AUD' => 'A\$',
    _ => '$currency ',
  };
  final text = amount == amount.roundToDouble()
      ? amount.toStringAsFixed(0)
      : amount.toStringAsFixed(2);
  return '$symbol$text';
}

/// What the Verified plan costs for one space, read from pricing_for()
/// (migration 115), and the two choices on it: monthly or yearly, and
/// the currency. Yearly is pre-selected and wears the "2 months free"
/// badge; the currency starts on the country's own and can be switched
/// unless the country locks it (the UK: pounds only).
class PricingChoice {
  final Map<String, dynamic> pricing;
  String period;
  String currency;

  PricingChoice(this.pricing, {this.period = 'yearly', String? currency})
      : currency = currency ?? '${pricing['currency'] ?? 'EUR'}';

  List<String> get currencies => [
        for (final c in (pricing['currencies'] as List? ?? const ['EUR'])) '$c'
      ];

  bool get locked => pricing['locked'] == true;

  /// Stripe has the prices, so Checkout can be used.
  bool get ready => pricing['ready'] == true;

  int? amount(String period, [String? cur]) {
    final m = pricing[period];
    if (m is! Map) return null;
    final v = m[cur ?? currency];
    return v is num ? v.toInt() : null;
  }

  int? get monthly => amount('monthly');
  int? get yearly => amount('yearly');
  int? get chosen => amount(period);

  /// "€10 a month" or "€99 a year".
  String get words {
    final a = chosen;
    if (a == null) return '';
    return '${formatMoney(a, currency)} a ${period == 'monthly' ? 'month' : 'year'}';
  }

  /// "from €10 a month", for headings and emails before a choice.
  String get fromWords {
    final a = monthly;
    return a == null ? '' : 'from ${formatMoney(a, currency)} a month';
  }

  /// The yearly saving against twelve monthly payments, as months.
  double get monthsFree {
    final m = monthly, y = yearly;
    if (m == null || y == null || m == 0) return 0;
    return 12 - y / m;
  }
}

class PricingPicker extends StatelessWidget {
  final PricingChoice choice;
  final void Function(PricingChoice) onChanged;

  /// The space's day pass price, when known ("€15"), for the line that
  /// puts the plan next to one visitor.
  final String? dayPass;
  final bool compact;

  const PricingPicker({
    super.key,
    required this.choice,
    required this.onChanged,
    this.dayPass,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = choice;
    final monthly = c.monthly, yearly = c.yearly;
    final big = !compact;
    final months = c.monthsFree;
    final perMonthOfYearly =
        yearly == null ? null : formatMoney(yearly / 12, c.currency);

    Widget seg(String value, String label, {String? badge}) {
      final on = c.period == value;
      return Expanded(
        child: GestureDetector(
          onTap: () => onChanged(c..period = value),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(vertical: 9),
            decoration: BoxDecoration(
                color: on ? Brand.surface : Colors.transparent,
                borderRadius: BorderRadius.circular(7),
                boxShadow: on
                    ? [
                        BoxShadow(
                            color: Colors.black.withValues(alpha: .08),
                            blurRadius: 4,
                            offset: const Offset(0, 1))
                      ]
                    : null),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(label,
                  style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: on ? Brand.ink : Brand.inkSecondary)),
              if (badge != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(badge,
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: on ? Brand.success : Brand.inkMuted)),
                ),
            ]),
          ),
        ),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(
          child: Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
                color: Brand.field, borderRadius: BorderRadius.circular(9)),
            child: Row(children: [
              seg('monthly', 'Monthly'),
              seg('yearly', 'Yearly',
                  badge: months >= 1
                      ? '${months.round()} month${months.round() == 1 ? '' : 's'} free'
                      : null),
            ]),
          ),
        ),
        if (c.currencies.length > 1 && !c.locked) ...[
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(
                color: Brand.field, borderRadius: BorderRadius.circular(9)),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: c.currency,
                isDense: true,
                borderRadius: BorderRadius.circular(10),
                style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: Brand.ink),
                items: [
                  for (final cur in c.currencies)
                    DropdownMenuItem(
                        value: cur,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          child: Text(cur),
                        )),
                ],
                onChanged: (v) {
                  if (v != null) onChanged(c..currency = v);
                },
              ),
            ),
          ),
        ],
      ]),
      SizedBox(height: big ? 14 : 10),
      Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Text(
            c.chosen == null ? '' : formatMoney(c.chosen!, c.currency),
            style: TextStyle(
                fontSize: big ? 34 : 26,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.8,
                height: 1,
                color: Brand.ink)),
        const SizedBox(width: 6),
        Padding(
          padding: const EdgeInsets.only(bottom: 3),
          child: Text(
              c.period == 'monthly'
                  ? 'a month'
                  : 'a year${perMonthOfYearly == null ? '' : '  ·  $perMonthOfYearly a month'}',
              style: TextStyle(
                  fontSize: big ? 14 : 13, color: Brand.inkSecondary)),
        ),
      ]),
      const SizedBox(height: 6),
      Text(
          [
            if (c.period == 'yearly' && monthly != null)
              'Billed once a year. Monthly is ${formatMoney(monthly, c.currency)}.'
            else if (c.period == 'monthly' && yearly != null)
              'Billed monthly, cancel any time. Yearly is ${formatMoney(yearly, c.currency)}.',
            if (dayPass != null && dayPass!.isNotEmpty)
              'Less than one day pass ($dayPass) a month.',
          ].join(' '),
          style: TextStyle(
              fontSize: big ? 13 : 12.5,
              height: 1.45,
              color: Brand.inkSecondary)),
    ]);
  }
}
