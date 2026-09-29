import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/supabase_service.dart';
import '../theme.dart';
import 'owner_screen.dart';
import '../widgets/ui.dart';

/// Email + Google sign-in. (Apple sign-in slots in here later once the
/// Apple Developer account exists, see docs/APPLE_SIGN_IN.md.)
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

  /// One of the two "which one are you?" cards.
  Widget _choice({
    required IconData icon,
    required String title,
    required String text,
    required bool selected,
    VoidCallback? onTap,
  }) =>
      Material(
        color: selected ? Brand.accentTint : Brand.surface,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                  color: selected ? Brand.red : Brand.border,
                  width: selected ? 1.5 : 1),
            ),
            child: Row(children: [
              Icon(icon,
                  size: 24, color: selected ? Brand.red : Brand.inkSecondary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      Text(text,
                          style: const TextStyle(
                              fontSize: 12.5,
                              height: 1.4,
                              color: Brand.inkSecondary)),
                    ]),
              ),
              const SizedBox(width: 8),
              Icon(selected ? Icons.check_circle : Icons.chevron_right,
                  color: selected ? Brand.red : Brand.inkMuted),
            ]),
          ),
        ),
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
              Image.asset('assets/brand/app_icon.png', height: 64),
              const SizedBox(height: 14),
              const Text('Sign in to Nomadwise',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 21, fontWeight: FontWeight.w800)),
              const SizedBox(height: 6),
              const Text('Which one are you?',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 14, color: Brand.inkSecondary)),
              const SizedBox(height: 16),
              // Two kinds of people sign in here: nomads looking for a
              // place to work (this screen) and the people who run the
              // places (their own Business sign-in).
              _choice(
                icon: Icons.travel_explore,
                title: 'I\'m looking for places to work',
                text: 'Find coworking spaces and cafes with good wifi, and '
                    'earn coins for reviewing the places you try.',
                selected: true,
              ),
              const SizedBox(height: 10),
              _choice(
                icon: Icons.storefront_outlined,
                title: 'I run a coworking space or cafe',
                text: 'Manage your listing on Nomadwise: photos, prices, '
                    'hours and details.',
                selected: false,
                onTap: () => Navigator.of(context).pushReplacement(
                    MaterialPageRoute(builder: (_) => const OwnerScreen())),
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
