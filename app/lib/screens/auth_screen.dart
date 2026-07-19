import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config.dart';
import '../services/supabase_service.dart';
import '../theme.dart';
import '../widgets/ui.dart';

/// Email + Google sign-in. (Apple sign-in slots in here later once the
/// Apple Developer account exists — see docs/APPLE_SIGN_IN.md.)
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});
  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _supabase = SupabaseService();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _signUp = false;
  bool _busy = false;
  String? _error;
  StreamSubscription? _authSub;

  @override
  void initState() {
    super.initState();
    // Google OAuth returns via deep link; close this screen when it lands.
    _authSub = _supabase.authChanges.listen((state) {
      if (state.event == AuthChangeEvent.signedIn && mounted) {
        Navigator.pop(context, true);
      }
    });
  }

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }

  Future<void> _doEmail() async {
    setState(() { _busy = true; _error = null; });
    try {
      if (_signUp) {
        await _supabase.signUpWithEmail(
            _email.text.trim(), _password.text);
        // Email confirmation is on: no session yet means Supabase has
        // sent a confirmation link. Tell the user what to do next.
        if (mounted && !_supabase.signedIn) {
          await showDialog(
              context: context,
              builder: (ctx) => AlertDialog(
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20)),
                    title: const Text('Check your inbox'),
                    content: Text(
                        'We sent a confirmation link to '
                        '${_email.text.trim()}. Tap it, then come back '
                        'here and sign in. (Check spam if it\'s not '
                        'there in a minute.)'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('Got it')),
                    ],
                  ));
          if (mounted) setState(() => _signUp = false);
          return;
        }
      } else {
        await _supabase.signInWithEmail(
            _email.text.trim(), _password.text);
      }
      if (mounted && _supabase.signedIn) Navigator.pop(context, true);
    } on AuthException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = 'Could not sign in. Please try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _doGoogle() async {
    setState(() { _busy = true; _error = null; });
    try {
      await _supabase.signInWithGoogle();
      // On web this redirects the whole page; on mobile the deep link
      // listener above closes this screen.
      if (kIsWeb) return;
    } catch (e) {
      setState(() => _error = 'Google sign-in failed. Please try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _authStat(String num, String label) => Expanded(
        child: Column(children: [
          Text(num,
              style: const TextStyle(
                  fontSize: 17, fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text(label,
              style: const TextStyle(
                  fontSize: 11, color: Brand.inkMuted)),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sign in')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child:
                Column(mainAxisSize: MainAxisSize.min, children: [
              Image.asset('assets/brand/app_icon.png', height: 76),
              const SizedBox(height: 14),
              const Text('Review spaces. Earn coins.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 19, fontWeight: FontWeight.w700)),
              const SizedBox(height: 12),

              // Why bother: what you earn, up front.
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 13),
                decoration: BoxDecoration(
                  color: Brand.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Brand.border),
                  boxShadow: Brand.shadowResting,
                ),
                child: Row(children: [
                  _authStat('+${AppConfig.coinsNewVenue}',
                      'per review'),
                  Container(
                      width: 1, height: 30, color: Brand.hairline),
                  _authStat('+${AppConfig.coinsWifiTest}',
                      'per wifi test'),
                ]),
              ),
              const SizedBox(height: 10),

              // And the point of it all: coins become real money.
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: Brand.goldTint,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(children: [
                  Row(
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
                  const SizedBox(height: 6),
                  Text(
                      'Convert to euros any time. Cash out from '
                      '€${AppConfig.minCashOutEuro}.',
                      style: const TextStyle(
                          fontSize: 12, color: Brand.goldTextDark)),
                ]),
              ),
              const SizedBox(height: 24),

              // Google first: one tap, no typing.
              Container(
                width: double.infinity,
                height: 50,
                decoration: BoxDecoration(
                  color: Brand.surface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Brand.border),
                  boxShadow: Brand.shadowResting,
                ),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: _busy ? null : _doGoogle,
                    child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Image.asset('assets/brand/google_g.png',
                              height: 20, width: 20),
                          const SizedBox(width: 12),
                          const Text('Continue with Google',
                              style: TextStyle(
                                  fontSize: 15.5,
                                  fontWeight: FontWeight.w600,
                                  color: Brand.ink)),
                        ]),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Row(children: [
                const Expanded(
                    child: Divider(color: Brand.hairline)),
                Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10),
                    child: Text('or with email',
                        style: TextStyle(
                            fontSize: 12.5,
                            color: Colors.grey.shade500))),
                const Expanded(
                    child: Divider(color: Brand.hairline)),
              ]),
              const SizedBox(height: 14),
              TextField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  decoration:
                      const InputDecoration(labelText: 'Email')),
              const SizedBox(height: 12),
              TextField(
                  controller: _password,
                  obscureText: true,
                  decoration:
                      const InputDecoration(labelText: 'Password')),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!,
                    style: const TextStyle(color: Brand.red)),
              ],
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                    onPressed: _busy ? null : _doEmail,
                    child: Text(_signUp
                        ? 'Create account'
                        : 'Sign in')),
              ),
              TextButton(
                  onPressed: () =>
                      setState(() => _signUp = !_signUp),
                  child: Text(_signUp
                      ? 'Already have an account? Sign in'
                      : 'New here? Create an account')),
              // Apple sign-in button will live here (post Apple Developer
              // enrolment). Keep structure ready:
              // SignInWithAppleButton(...)
            ]),
          ),
        ),
      ),
    );
  }
}
