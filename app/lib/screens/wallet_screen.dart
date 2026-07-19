import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../config.dart';
import '../services/analytics_service.dart';
import '../services/supabase_service.dart';
import '../theme.dart';
import '../widgets/ui.dart';

class WalletScreen extends StatefulWidget {
  const WalletScreen({super.key});
  @override
  State<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends State<WalletScreen> {
  final _supabase = SupabaseService();
  ({int withdrawable, int pending, int total})? _wallet;
  int _euroCents = 0;
  bool _converting = false;
  List<Map<String, dynamic>> _ledger = [];

  @override
  void initState() {
    super.initState();
    _load();
    Analytics.capture('wallet_viewed');
  }

  Future<void> _load() async {
    final w = await _supabase.wallet();
    final e = await _supabase.euroCents();
    final l = await _supabase.ledger();
    if (mounted) {
      setState(() {
        _wallet = w;
        _euroCents = e;
        _ledger = l;
      });
    }
  }

  String _eur(int cents) => (cents / 100).toStringAsFixed(2);

  Future<void> _convert() async {
    final w = _wallet;
    if (w == null || w.withdrawable <= 0 || _converting) return;
    final euros = _eur(w.withdrawable); // 1 coin = 1 cent
    final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20)),
              title: const Text('Convert to euros?'),
              content: Text(
                  '${w.withdrawable} coins become €$euros in your euro '
                  'balance. Your leaderboard score keeps every coin you '
                  'have ever earned, so your rank stays exactly where '
                  'it is.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Cancel')),
                ElevatedButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: Text('Convert to €$euros')),
              ],
            ));
    if (ok != true || !mounted) return;
    setState(() => _converting = true);
    final res = await _supabase.convertCoins();
    if (mounted) setState(() => _converting = false);
    if (res == null || res.coins == 0) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Could not convert right now. Please try again.')));
      }
      return;
    }
    Analytics.capture('coins_converted', {'coins': res.coins});
    await _load();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              '€${_eur(res.cents)} added to your euro balance.')));
    }
  }

  void _cashOut() {
    final minCents = AppConfig.minCashOutEuro * 100;
    if (_euroCents < minCents) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          duration: const Duration(seconds: 4),
          content: Text(
              '€${_eur(minCents - _euroCents)} to go until the '
              '€${AppConfig.minCashOutEuro} minimum cash-out. '
              'Keep reviewing!')));
      return;
    }
    Analytics.capture('cashout_requested', {'cents': _euroCents});
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        duration: Duration(seconds: 5),
        content: Text(
            'You reached the minimum! The Nomadwise team will be in '
            'touch to pay you out.')));
  }

  @override
  Widget build(BuildContext context) {
    final w = _wallet;
    final progress = (_euroCents /
            (AppConfig.minCashOutEuro * 100))
        .clamp(0.0, 1.0);
    return Scaffold(
      appBar: AppBar(title: const Text('Wallet'), actions: [
        IconButton(
            tooltip: 'Sign out',
            onPressed: () async {
              await _supabase.signOut();
              if (context.mounted) Navigator.pop(context);
            },
            icon: const Icon(Icons.logout))
      ]),
      body: w == null
          ? const Center(
              child: CircularProgressIndicator(color: Brand.red))
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    // ---- balance card ----
                    Container(
                      padding: const EdgeInsets.all(22),
                      decoration: BoxDecoration(
                          color: Brand.goldTint,
                          borderRadius: BorderRadius.circular(22)),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('WITHDRAWABLE COINS',
                                style: TextStyle(
                                    color: Brand.goldTextDark,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 1.2)),
                            const SizedBox(height: 6),
                            Row(
                                crossAxisAlignment:
                                    CrossAxisAlignment.end,
                                children: [
                                  const CoinDot(size: 30),
                                  const SizedBox(width: 10),
                                  Text('${w.withdrawable}',
                                      style: const TextStyle(
                                          color: Brand.ink,
                                          fontSize: 40,
                                          fontWeight: FontWeight.w700,
                                          height: 1)),
                                  const SizedBox(width: 10),
                                  Padding(
                                    padding: const EdgeInsets.only(
                                        bottom: 3),
                                    child: Text(
                                        '= €${(w.withdrawable / AppConfig.coinsPerEuro).toStringAsFixed(2)}',
                                        style: const TextStyle(
                                            color: Brand.goldTextDark,
                                            fontSize: 17,
                                            fontWeight:
                                                FontWeight.w700)),
                                  ),
                                ]),
                            if (w.pending > 0) ...[
                              const SizedBox(height: 8),
                              Text(
                                  '+ ${w.pending} pending verification',
                                  style: const TextStyle(
                                      color: Brand.goldTextDark,
                                      fontWeight: FontWeight.w500)),
                            ],
                            const SizedBox(height: 14),
                            SizedBox(
                              width: double.infinity,
                              height: 44,
                              child: ElevatedButton.icon(
                                onPressed:
                                    w.withdrawable > 0 && !_converting
                                        ? _convert
                                        : null,
                                icon: _converting
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child:
                                            CircularProgressIndicator(
                                                strokeWidth: 2,
                                                color: Colors.white))
                                    : const Icon(
                                        Icons.currency_exchange,
                                        size: 18),
                                label: Text(w.withdrawable > 0
                                    ? 'Convert to €${_eur(w.withdrawable)}'
                                    : 'Nothing to convert yet'),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '${AppConfig.coinsPerEuro} coins = €1. '
                              'Converting never lowers your '
                              'leaderboard score.',
                              style: const TextStyle(
                                  color: Brand.goldTextDark,
                                  fontSize: 11.5),
                            ),
                          ]),
                    ),
                    const SizedBox(height: 12),

                    // ---- euro balance card ----
                    Container(
                      padding: const EdgeInsets.all(22),
                      decoration: BoxDecoration(
                          color: Brand.successTint,
                          borderRadius: BorderRadius.circular(22)),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('EURO BALANCE',
                                style: TextStyle(
                                    color: Brand.success,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 1.2)),
                            const SizedBox(height: 6),
                            Text('€${_eur(_euroCents)}',
                                style: const TextStyle(
                                    color: Brand.ink,
                                    fontSize: 40,
                                    fontWeight: FontWeight.w700,
                                    height: 1)),
                            const SizedBox(height: 16),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: LinearProgressIndicator(
                                value: progress,
                                minHeight: 10,
                                backgroundColor: Colors.white,
                                color: Brand.success,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              progress >= 1
                                  ? 'You reached the €${AppConfig.minCashOutEuro} minimum!'
                                  : '€${_eur(_euroCents)} of the €${AppConfig.minCashOutEuro} minimum cash-out',
                              style: const TextStyle(
                                  color: Brand.success,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13),
                            ),
                            const SizedBox(height: 12),
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton.icon(
                                  style: ElevatedButton.styleFrom(
                                      backgroundColor: Brand.success),
                                  onPressed: _cashOut,
                                  icon: const Icon(Icons.euro),
                                  label: const Text('Cash out')),
                            ),
                          ]),
                    ),
                    const SizedBox(height: 16),
                    const Text('HISTORY',
                        style: TextStyle(
                            color: Brand.red,
                            fontWeight: FontWeight.w900,
                            fontSize: 13,
                            letterSpacing: 1)),
                    const SizedBox(height: 6),
                    if (_ledger.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          'No coins yet. Review or confirm a space on the map '
                          'to start earning!',
                          textAlign: TextAlign.center,
                          style:
                              TextStyle(color: Colors.grey.shade600),
                        ),
                      ),
                    ..._ledger.map(_ledgerTile),
                  ]),
            ),
    );
  }

  Widget _ledgerTile(Map<String, dynamic> r) {
    final amount = r['amount'] as int;
    final status = r['status'] as String;
    final date = DateTime.tryParse(r['created_at'] ?? '');
    final pending = status == 'pending';
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: amount < 0
          ? const Icon(Icons.currency_exchange, color: Brand.success)
          : Icon(
              pending ? Icons.hourglass_top : Icons.monetization_on,
              color: pending ? Colors.grey.shade400 : Brand.amber,
            ),
      title: Text(r['note'] ?? 'Coins'),
      subtitle: Text(
        [
          if (date != null) DateFormat('d MMM yyyy').format(date),
          if (pending) 'pending verification',
          if (status == 'cancelled') 'not verified',
        ].join(' · '),
      ),
      trailing: Text(
        '${amount > 0 ? '+' : ''}$amount',
        style: TextStyle(
            fontWeight: FontWeight.w900,
            fontSize: 16,
            color: status == 'cancelled'
                ? Colors.grey.shade400
                : (pending ? Colors.grey.shade500 : Brand.charcoal)),
      ),
    );
  }
}
