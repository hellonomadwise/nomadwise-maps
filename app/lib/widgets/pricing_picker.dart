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

  /// The country is known and in a pricing group. When it is not (no
  /// space picked yet, or an address we could not place) the amounts
  /// are the fallback group's, so headings say "from €4" instead.
  bool get mapped => pricing['mapped'] == true;

  /// The cheapest Verified price anywhere, in euro cents (migration 118).
  int? get fromMonthlyEur {
    final v = pricing['from_monthly_eur'];
    return v is num ? v.toInt() : null;
  }

  int? get fromYearlyEur {
    final v = pricing['from_yearly_eur'];
    return v is num ? v.toInt() : null;
  }

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

  /// "from €10 a month" for headings before a choice. With no country
  /// yet, the cheapest price anywhere: "from €4 a month".
  String get fromWords {
    if (!mapped && fromMonthlyEur != null) {
      return 'from ${formatMoney(fromMonthlyEur!, 'EUR')} a month';
    }
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

/// Monthly / Yearly, the way pricing pages do it: the two words with a
/// switch between them and a "2 months free" pill on the yearly side.
/// Tapping either word also switches.
class PeriodToggle extends StatelessWidget {
  final PricingChoice choice;
  final void Function(PricingChoice) onChanged;

  const PeriodToggle({super.key, required this.choice, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final c = choice;
    final yearly = c.period == 'yearly';
    final months = c.monthsFree.round();

    Widget word(String label, String value) {
      final on = c.period == value;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onChanged(c..period = value),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text(label,
              style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: on ? FontWeight.w800 : FontWeight.w600,
                  color: on ? Brand.ink : Brand.inkSecondary)),
        ),
      );
    }

    return Row(mainAxisSize: MainAxisSize.min, children: [
      word('Monthly', 'monthly'),
      const SizedBox(width: 8),
      SizedBox(
        height: 30,
        child: FittedBox(
          child: Switch(
            value: yearly,
            thumbColor: const WidgetStatePropertyAll(Colors.white),
            trackColor: WidgetStateProperty.resolveWith((states) =>
                states.contains(WidgetState.selected)
                    ? Brand.red
                    : Brand.inkFaint),
            trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
            onChanged: (v) => onChanged(c..period = v ? 'yearly' : 'monthly'),
          ),
        ),
      ),
      const SizedBox(width: 8),
      word('Yearly', 'yearly'),
      if (months >= 1) ...[
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
              color: yearly ? Brand.successTint : Brand.field,
              borderRadius: BorderRadius.circular(20)),
          child: Text('$months month${months == 1 ? '' : 's'} free',
              style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                  color: yearly ? Brand.success : Brand.inkMuted)),
        ),
      ],
    ]);
  }
}

/// "Prices in: EUR", for countries that can pay in more than one
/// currency. Nothing is drawn when there is only one (the UK).
class CurrencyPicker extends StatelessWidget {
  final PricingChoice choice;
  final void Function(PricingChoice) onChanged;

  const CurrencyPicker(
      {super.key, required this.choice, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final c = choice;
    if (c.currencies.length < 2 || c.locked) return const SizedBox.shrink();
    return Row(mainAxisSize: MainAxisSize.min, children: [
      const Text('Prices in',
          style: TextStyle(fontSize: 13, color: Brand.inkSecondary)),
      const SizedBox(width: 8),
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
                fontSize: 13.5, fontWeight: FontWeight.w700, color: Brand.ink),
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
    ]);
  }
}
