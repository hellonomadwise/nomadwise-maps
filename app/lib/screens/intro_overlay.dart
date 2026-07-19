import 'package:flutter/material.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import '../services/analytics_service.dart';
import '../theme.dart';
import '../widgets/ui.dart';

/// First-run welcome: three quick cards that explain the game.
/// Shown once per device, always skippable.
Future<void> showIntroIfNeeded(BuildContext context) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('intro_seen_v1') == true) return;
    if (!context.mounted) return;
    Analytics.capture('intro_shown');
    await showGeneralDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.transparent,
      pageBuilder: (_, __, ___) =>
          PointerInterceptor(child: const _IntroOverlay()),
    );
    await prefs.setBool('intro_seen_v1', true);
  } catch (_) {}
}

class _IntroOverlay extends StatefulWidget {
  const _IntroOverlay();
  @override
  State<_IntroOverlay> createState() => _IntroOverlayState();
}

class _IntroOverlayState extends State<_IntroOverlay> {
  final _controller = PageController();
  int _page = 0;

  void _finish(String how) {
    Analytics.capture(how);
    Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Brand.bg,
      child: SafeArea(
        child: Column(children: [
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(0, 8, 12, 0),
              child: TextButton(
                onPressed: () => _finish('intro_skipped'),
                child: const Text('Skip',
                    style: TextStyle(
                        color: Brand.inkMuted,
                        fontWeight: FontWeight.w600)),
              ),
            ),
          ),
          Expanded(
            child: PageView(
              controller: _controller,
              onPageChanged: (i) => setState(() => _page = i),
              children: [
                _card(
                  art: _artCircle(
                      Brand.accentTint,
                      Image.asset('assets/pins/pin_yes.png',
                          height: 52)),
                  title: 'Find places to work',
                  body:
                      'Work-friendly cafes and coworking spaces around '
                      'the world, checked by nomads like you. WiFi '
                      'speeds, plugs, laptop rules, even the WiFi '
                      'password.',
                ),
                _card(
                  art: _artCircle(
                      Brand.goldTint, const CoinDot(size: 52)),
                  title: 'Earn coins for helping',
                  body:
                      'Every real contribution pays. Review a space, '
                      'test its WiFi, or be the first to put a place '
                      'on the map.',
                  extra: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      alignment: WrapAlignment.center,
                      children: [
                        CoinChip(
                            '+${AppConfig.coinsNewVenue} review',
                            height: 26),
                        CoinChip(
                            '+${AppConfig.coinsWifiTest} wifi test',
                            height: 26),
                        CoinChip(
                            '+${AppConfig.coinsDiscovery} discovery',
                            height: 26),
                      ]),
                ),
                _card(
                  art: _artCircle(
                      Brand.successTint,
                      const Icon(Icons.euro,
                          size: 44, color: Brand.success)),
                  title: 'Coins become real money',
                  body:
                      'Convert your coins to euros whenever you like '
                      'and cash out from €${AppConfig.minCashOutEuro}. '
                      'Your leaderboard glory stays forever.',
                  extra: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const CoinDot(size: 18),
                        const SizedBox(width: 6),
                        Text('${AppConfig.coinsPerEuro} coins',
                            style: const TextStyle(
                                fontSize: 14.5,
                                fontWeight: FontWeight.w700)),
                        const SizedBox(width: 10),
                        const Icon(Icons.arrow_forward,
                            size: 16, color: Brand.goldLink),
                        const SizedBox(width: 10),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 3),
                          decoration: BoxDecoration(
                              color: Brand.success,
                              borderRadius:
                                  BorderRadius.circular(9)),
                          child: const Text('€1',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w800)),
                        ),
                      ]),
                ),
              ],
            ),
          ),
          Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(3, (i) {
                final on = i == _page;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  width: on ? 22 : 8,
                  height: 8,
                  decoration: BoxDecoration(
                      color: on ? Brand.accent : Brand.inkFaint,
                      borderRadius: BorderRadius.circular(4)),
                );
              })),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
            child: PrimaryCta(
              label:
                  _page < 2 ? 'Next' : 'Start exploring',
              onPressed: () {
                if (_page < 2) {
                  _controller.nextPage(
                      duration: const Duration(milliseconds: 260),
                      curve: Curves.easeOut);
                } else {
                  _finish('intro_completed');
                }
              },
            ),
          ),
        ]),
      ),
    );
  }

  Widget _artCircle(Color bg, Widget child) => Container(
        width: 104,
        height: 104,
        decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
        child: Center(child: child),
      );

  Widget _card(
      {required Widget art,
      required String title,
      required String body,
      Widget? extra}) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            art,
            const SizedBox(height: 26),
            Text(title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 22, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            Text(body,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 14.5,
                    height: 1.55,
                    color: Brand.inkSecondary)),
            if (extra != null) ...[
              const SizedBox(height: 18),
              extra,
            ],
          ]),
        ),
      ),
    );
  }
}
