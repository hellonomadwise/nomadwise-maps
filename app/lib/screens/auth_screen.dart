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

              // Why bother: the coins, up front.
              Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    CoinChip('+${AppConfig.coinsNewVenue} per review',
                        height: 26),
                    CoinChip(
                        '+${AppConfig.coinsWifiTest} per wifi test',
                        height: 26),
                    CoinChip(
                        '${AppConfig.cashOutThreshold} = '
                        '${AppConfig.cashOutValueEuro} euro',
                        height: 26),
                  ]),
              const SizedBox(height: 26),

              // Google first: one tap, no typing.
              SizedBox(
                width: double.infinity,
                height: 50,
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _doGoogle,
                  icon: const Icon(Icons.g_mobiledata,
                      size: 30, color: Brand.ink),
                  label: const Text('Continue with Google',
                      style: TextStyle(
                          fontSize: 15.5,
                          fontWeight: FontWeight.w700)),
                  style: OutlinedButton.styleFrom(
                    backgroundColor: Brand.surface,
                    side: const BorderSide(
                        color: Brand.ink, width: 1.4),
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
