import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/supabase_service.dart';
import '../theme.dart';

/// Where a sign-in email's button lands (nomadmaps.io/owner?token_hash=
/// ...&type=magiclink, or /?token_hash=...&type=signup).
///
/// Cafe AMANO, 16 Oct 2026: the link in the email brought them back to
/// "Email me a sign-in link", every time. Two things break the old
/// link, which went straight to Supabase and signed in on arrival:
///   * company mail systems (Outlook's Safe Links and the like) open
///     every link in an email to check it, before the person does. The
///     link works once, so the check used it up and the real click
///     found it spent;
///   * the old link only worked in the browser that asked for it, so
///     asking on a computer and tapping the link on a phone, or in a
///     mail app that opens its own browser, failed too.
/// This page signs in only when the person presses Continue (a mail
/// checker opens the page but never presses anything), and it works in
/// any browser on any device.
class SignInLinkScreen extends StatefulWidget {
  final String tokenHash;
  final String type;

  /// True when the link was for the Owner account (/owner).
  final bool owner;

  const SignInLinkScreen(
      {super.key,
      required this.tokenHash,
      required this.type,
      required this.owner});

  @override
  State<SignInLinkScreen> createState() => _SignInLinkScreenState();
}

class _SignInLinkScreenState extends State<SignInLinkScreen> {
  bool _busy = false;
  String? _error;

  OtpType get _otpType => switch (widget.type) {
        'signup' => OtpType.signup,
        'email' => OtpType.email,
        'invite' => OtpType.invite,
        _ => OtpType.magiclink,
      };

  Future<void> _continue() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Supabase.instance.client.auth
          .verifyOTP(type: _otpType, tokenHash: widget.tokenHash);
      // An owner goes to their account; anyone else to the map. A new
      // owner's first email is the "confirm" one, so it is asked.
      var dest = '/';
      if (widget.owner) {
        dest = '/owner';
      } else {
        try {
          final s = SupabaseService();
          final rows = await s.ownerVenues();
          final pending = await s.ownerPendingClaims();
          if (rows.isNotEmpty || pending.isNotEmpty) dest = '/owner';
        } catch (_) {}
      }
      await launchUrl(Uri.parse(dest), webOnlyWindowName: '_self');
    } on AuthRetryableFetchException catch (_) {
      // No connection or a timeout: the link itself may still be good.
      if (mounted) {
        setState(() => _error =
            'That did not work just now. Please check your connection and '
            'press Continue again.');
      }
    } on AuthException catch (_) {
      if (mounted) {
        setState(() => _error = widget.owner
            ? 'This sign-in link has expired or has already been used. '
                'Ask for a new one below and use the newest email.'
            : 'This link has expired or has already been used. If you '
                'have already confirmed, just sign in from the map.');
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error =
            'That did not work just now. Please try again, or ask for a '
            'new link below.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Brand.bg,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Container(
              padding: const EdgeInsets.fromLTRB(26, 28, 26, 24),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Brand.border),
              ),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('nomadwise',
                        style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 22,
                            color: Brand.red)),
                    const SizedBox(height: 18),
                    Text(
                        widget.owner
                            ? 'Sign in to your Owner account'
                            : 'Confirm your email address',
                        style: const TextStyle(
                            fontSize: 20, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    const Text('Press Continue to finish signing in.',
                        style: TextStyle(
                            color: Brand.inkSecondary,
                            fontSize: 14,
                            height: 1.45)),
                    if (_error != null) ...[
                      const SizedBox(height: 14),
                      Text(_error!,
                          style: const TextStyle(
                              color: Brand.red, fontSize: 13.5, height: 1.4)),
                    ],
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: _busy ? null : _continue,
                      style: FilledButton.styleFrom(
                          backgroundColor: Brand.red,
                          minimumSize: const Size.fromHeight(50)),
                      child: Text(_busy ? 'One moment' : 'Continue',
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w700)),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 10),
                      OutlinedButton(
                        onPressed: () => launchUrl(
                            Uri.parse(widget.owner ? '/owner' : '/'),
                            webOnlyWindowName: '_self'),
                        style: OutlinedButton.styleFrom(
                            minimumSize: const Size.fromHeight(46)),
                        child: Text(widget.owner
                            ? 'Ask for a new sign-in link'
                            : 'Go to the map'),
                      ),
                    ],
                  ]),
            ),
          ),
        ),
      ),
    );
  }
}
