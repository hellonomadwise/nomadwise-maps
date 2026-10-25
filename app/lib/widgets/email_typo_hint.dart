import 'package:flutter/material.dart';

import '../theme.dart';

// "Did you mean ...?" under an email box (Jonathan, 25 Oct 2026: a new
// owner typed dadaicafe.con, the confirmation email bounced, and nobody
// would have known). A gentle hint, never a block: the address can be
// sent as typed.

/// Endings that are not real domains, and the one meant.
const Map<String, String> _tldFixes = {
  'con': 'com', 'cpm': 'com', 'vom': 'com', 'xom': 'com', 'cim': 'com',
  'ocm': 'com', 'cmo': 'com', 'comm': 'com', 'coom': 'com', 'c0m': 'com',
  'nte': 'net', 'nett': 'net', 'ner': 'net',
  'ogr': 'org', 'orgg': 'org', 'prg': 'org',
};

/// Common mail providers. A domain one or two keystrokes from one of
/// these (gmial.com, hotmail.co, outlok.com) gets that one suggested;
/// a domain in this list exactly is left alone.
const List<String> _providers = [
  'gmail.com', 'googlemail.com', 'yahoo.com', 'yahoo.co.uk', 'yahoo.fr',
  'yahoo.es', 'yahoo.de', 'hotmail.com', 'hotmail.co.uk', 'hotmail.fr',
  'hotmail.es', 'hotmail.de', 'hotmail.it', 'outlook.com', 'outlook.de',
  'outlook.es', 'outlook.fr', 'live.com', 'live.co.uk', 'msn.com',
  'icloud.com', 'me.com', 'mac.com', 'aol.com', 'proton.me',
  'protonmail.com', 'gmx.de', 'gmx.net', 'gmx.com', 'web.de', 't-online.de',
  'mail.com', 'zoho.com', 'yandex.com', 'libero.it', 'orange.fr',
  'free.fr', 'btinternet.com', 'sky.com', 'comcast.net', 'qq.com',
  // Real, and close to the ones above: listed so they are never "fixed".
  'email.com', 'ymail.com', 'rocketmail.com', 'hey.com', 'fastmail.com',
  'posteo.de', 'mailbox.org', 'tutanota.com', 'gmx.at', 'gmx.ch',
];

/// Optimal string alignment distance (a swap of two letters counts once).
int _distance(String a, String b) {
  final d = List.generate(a.length + 1, (_) => List<int>.filled(b.length + 1, 0));
  for (var i = 0; i <= a.length; i++) {
    d[i][0] = i;
  }
  for (var j = 0; j <= b.length; j++) {
    d[0][j] = j;
  }
  for (var i = 1; i <= a.length; i++) {
    for (var j = 1; j <= b.length; j++) {
      final cost = a[i - 1] == b[j - 1] ? 0 : 1;
      var v = d[i - 1][j] + 1;
      if (d[i][j - 1] + 1 < v) v = d[i][j - 1] + 1;
      if (d[i - 1][j - 1] + cost < v) v = d[i - 1][j - 1] + cost;
      if (i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1] &&
          d[i - 2][j - 2] + 1 < v) {
        v = d[i - 2][j - 2] + 1;
      }
      d[i][j] = v;
    }
  }
  return d[a.length][b.length];
}

/// The address probably meant, or null when [typed] looks fine (or is
/// not an address yet).
String? emailSuggestion(String typed) {
  final t = typed.trim();
  final at = t.lastIndexOf('@');
  if (at < 1 || at != t.indexOf('@') || at == t.length - 1) return null;
  final local = t.substring(0, at);
  final domain = t.substring(at + 1).toLowerCase();
  if (domain.contains(' ')) return null;

  // A known provider, a keystroke or two off.
  if (!_providers.contains(domain) && domain.length >= 6) {
    String? best;
    var bestD = 3;
    for (final p in _providers) {
      final dist = _distance(domain, p);
      if (dist < bestD) {
        bestD = dist;
        best = p;
      }
    }
    // One slip anywhere, or two in the name itself when the ending is
    // the same (gmaail.com). Never two in the ending: outlook.it is real.
    if (best != null) {
      final sameEnd = domain.contains('.') &&
          domain.substring(domain.indexOf('.')) ==
              best.substring(best.indexOf('.'));
      // A short name with the same ending (wed.de, web.de) may well be
      // a real business: left alone.
      final shortName = sameEnd && best.indexOf('.') < 4;
      if (!shortName &&
          (bestD == 1 || (bestD == 2 && sameEnd && best.indexOf('.') >= 5))) {
        // Same provider, another country (hotmail.be, yahoo.se): real.
        final tName = domain.split('.').first;
        final bName = best.split('.').first;
        final tEnd = domain.substring(domain.lastIndexOf('.') + 1);
        final bEnd = best.substring(best.lastIndexOf('.') + 1);
        if (tName == bName && tEnd.length == 2 && bEnd.length == 2) {
          return null;
        }
        return '$local@$best';
      }
    }
  }

  // An ending that does not exist (.con for .com).
  final dot = domain.lastIndexOf('.');
  if (dot > 0 && dot < domain.length - 1) {
    final fix = _tldFixes[domain.substring(dot + 1)];
    if (fix != null) return '$local@${domain.substring(0, dot)}.$fix';
  }
  return null;
}

/// Shown under an email box: "Did you mean x? Use it". Nothing at all
/// when the address looks fine. [onUse] runs after the box is changed,
/// for forms that check the address themselves.
class EmailTypoHint extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback? onUse;
  const EmailTypoHint({super.key, required this.controller, this.onUse});

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final s = emailSuggestion(controller.text);
          if (s == null) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Container(
              padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
              decoration: BoxDecoration(
                  color: Brand.goldTint,
                  borderRadius: BorderRadius.circular(8)),
              child: Row(children: [
                const Icon(Icons.spellcheck, size: 16, color: Brand.goldTextDark),
                const SizedBox(width: 8),
                Expanded(
                  child: Text.rich(
                    TextSpan(children: [
                      const TextSpan(text: 'Did you mean '),
                      TextSpan(
                          text: s,
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                      const TextSpan(text: '?'),
                    ]),
                    style: const TextStyle(
                        fontSize: 13, height: 1.3, color: Brand.goldTextDark),
                  ),
                ),
                TextButton(
                  onPressed: () {
                    controller.value = TextEditingValue(
                        text: s,
                        selection: TextSelection.collapsed(offset: s.length));
                    onUse?.call();
                  },
                  style: TextButton.styleFrom(
                      foregroundColor: Brand.goldTextDark,
                      visualDensity: VisualDensity.compact),
                  child: const Text('Use it',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                ),
              ]),
            ),
          );
        },
      );
}
