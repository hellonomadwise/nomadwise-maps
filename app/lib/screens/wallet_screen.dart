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
  List<Map<String, dynamic>> _ledger = [];

  @override
  void initState() {
    super.initState();
    _load();
    Analytics.capture('wallet_viewed');
  }

  Future<void> _load() async {
    final w = await _supabase.wallet();
    final l = await _supabase.ledger();
    if (mounted) setState(() { _wallet = w; _ledger = l; });
  }

  @override
  Widget build(BuildContext context) {
    final w = _wallet;
    final progress = w == null
        ? 0.0
        : (w.withdrawable / AppConfig.cashOutThreshold).clamp(0.0, 1.0);
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
                            const SizedBox(height: 18),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: LinearProgressIndicator(
                                value: progress,
                                minHeight: 10,
                                backgroundColor: Colors.white,
                                color: Brand.gold,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '€${(w.withdrawable / AppConfig.coinsPerEuro).toStringAsFixed(2)} of the '
                              '€${AppConfig.minCashOutEuro} minimum cash-out',
                              style: const TextStyle(
                                  color: Brand.goldTextDark,
                                  fontWeight: FontWeight.w500,
                                  fontSize: 13),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '${AppConfig.coinsPerEuro} coins = €1. '
                              'Convert any time, cash out from '
                              '€${AppConfig.minCashOutEuro}.',
                              style: const TextStyle(
                                  color: Brand.goldTextDark,
                                  fontSize: 11.5),
                            ),
                          ]),
                    ),
                    const SizedBox(height: 12),
                    if (progress >= 1)
                      ElevatedButton.icon(
                          onPressed: () => ScaffoldMessenger.of(context)
                              .showSnackBar(const SnackBar(
                                  content: Text(
                                      'Cash-out requests open soon. Your coins are safe!'))),
                          icon: const Icon(Icons.euro),
                          label: const Text('Request cash-out')),
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
      leading: Icon(
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
