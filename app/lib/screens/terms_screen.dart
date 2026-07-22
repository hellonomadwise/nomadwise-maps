import 'package:flutter/material.dart';

import '../services/analytics_service.dart';
import '../theme.dart';

/// Terms of service, written in plain language.
///
/// The legally important part is the coin section: coins have no cash
/// value until a cash-out is reviewed and approved by us, payouts are
/// discretionary and capped, and fraud voids balances. This is what
/// turns "pay me for my farmed coins" into an empty demand.
class TermsScreen extends StatelessWidget {
  const TermsScreen({super.key});

  static const _updated = '22 July 2026';

  @override
  Widget build(BuildContext context) {
    Analytics.capture('terms_viewed');
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text('Terms of service'),
        backgroundColor: Colors.white,
        foregroundColor: Brand.ink,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        children: [
          Text('Plain-language terms · last updated $_updated',
              style: const TextStyle(
                  fontSize: 12.5, color: Brand.inkSecondary)),
          const SizedBox(height: 16),
          _section(
            'Who we are',
            'Nomad Maps (nomadmaps.io) is operated by the team behind '
                'nomadwise.io. Questions or requests any time: '
                'hello@nomadwise.io.',
          ),
          _section(
            'What Nomad Maps is',
            'A community map of cafes and coworking spaces that are good '
                'to work from. Details like WiFi speeds, amenities and '
                'opening hours are gathered from our own visits, public '
                'sources and community contributions. We work hard to keep '
                'it accurate, but places change, so nothing here is a '
                'guarantee and you use the information at your own '
                'judgement.',
          ),
          _section(
            'Coins are a reward system, not money',
            'Coins are reward points that thank you for useful, honest '
                'contributions. They are not a currency and not a wallet '
                'balance. Specifically:\n\n'
                '•  Coins have no cash value until a cash-out request '
                'has been reviewed and approved by us.\n'
                '•  Approval is at our discretion and always follows a '
                'human review of the contributions behind the balance.\n'
                '•  Cash-outs start at the €50 equivalent, and '
                'total monthly payouts are capped while the project is '
                'young, so requests can queue for the next month.\n'
                '•  Coins cannot be transferred, sold or exchanged '
                'between accounts.\n'
                '•  Dishonest contributions void the coins earned from '
                'them, and can void the whole balance and the account. '
                'That includes submissions made without visiting the place, '
                'automated or mass-produced submissions, copied photos and '
                'made-up details.\n'
                '•  We may change how many coins actions earn; changes '
                'never remove coins you earned honestly before the change.',
          ),
          _section(
            'Honest contributions',
            'Submissions must be about a real visit: you were physically '
                'there, the photo is yours and recent, and the details are '
                'true as far as you can tell. We review submissions before '
                'they count, and we may decline any submission without it '
                'earning coins.',
          ),
          _section(
            'Your content',
            'You keep ownership of the photos and information you submit, '
                'and you give us permission to show and use them in Nomad '
                'Maps and nomadwise.io, including in edited or curated '
                'form.',
          ),
          _section(
            'Your account and data',
            'Sign-in uses your Google account; we never see or store your '
                'password. We store your email, display name and your '
                'contributions. Email hello@nomadwise.io to delete your '
                'account and data, and we will do it.',
          ),
          _section(
            'Changes to these terms',
            'If these terms change, the date at the top changes with them, '
                'and meaningful changes will be visible in the app. Using '
                'Nomad Maps after a change means the new terms apply.',
          ),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
            decoration: BoxDecoration(
              color: Brand.ink,
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('IN SHORT',
                    style: TextStyle(
                        color: Brand.gold,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.6)),
                SizedBox(height: 8),
                Text(
                  'Genuine contributions are always rewarded. '
                  'Fraudulent activity forfeits both the coins and '
                  'the account.',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w500,
                      height: 1.55),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _section(String title, String body) => Padding(
        padding: const EdgeInsets.only(bottom: 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
                    color: Brand.ink)),
            const SizedBox(height: 6),
            Text(body,
                style: const TextStyle(
                    fontSize: 13.5, height: 1.5, color: Brand.inkSecondary)),
          ],
        ),
      );
}
