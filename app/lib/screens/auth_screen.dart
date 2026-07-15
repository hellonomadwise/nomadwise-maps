import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/supabase_service.dart';
import '../theme.dart';

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
              Image.asset('assets/brand/app_icon.png', height: 84),
              const SizedBox(height: 14),
              const Text('Earn coins for helping nomads\nfind places to work',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w500)),
              const SizedBox(height: 26),
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
              const SizedBox(height: 6),
              Row(children: [
                Expanded(child: Divider(color: Colors.grey.shade300)),
                const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 10),
                    child: Text('or')),
                Expanded(child: Divider(color: Colors.grey.shade300)),
              ]),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _doGoogle,
                  icon: const Icon(Icons.g_mobiledata, size: 28),
                  label: const Text('Continue with Google'),
                  style: OutlinedButton.styleFrom(
                      padding:
                          const EdgeInsets.symmetric(vertical: 13)),
                ),
              ),
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
