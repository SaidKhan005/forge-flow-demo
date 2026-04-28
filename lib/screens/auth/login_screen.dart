// Phase 9.3 - Minimal login screen.
//
// Email + password form with one "Sign in" action. On success the
// notifier transitions to authenticated and the AuthGate swaps to
// the app shell. On MFA required the gate swaps to the TOTP
// challenge placeholder (real TOTP UI lands in 9.4). On failure the
// error message renders in a banner above the form.
//
// The screen is intentionally bare: dense layout, no marketing
// copy, no branding chrome beyond the existing app theme. Rich
// branded action-link pages (invite, password reset, email verify)
// are owned by the Forge & Flow web app, not the Flutter shell.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/auth_session_notifier.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    if (email.isEmpty || password.isEmpty) {
      return;
    }
    setState(() => _submitting = true);
    try {
      await context.read<AuthSessionNotifier>().signInWithEmailPassword(
        email: email,
        password: password,
      );
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final notifier = context.watch<AuthSessionNotifier>();
    final state = notifier.state;
    final errorMessage = state is AuthSessionUnauthenticated
        ? state.lastErrorMessage
        : null;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Sign in',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 24),
                if (errorMessage != null) ...[
                  _ErrorBanner(message: errorMessage),
                  const SizedBox(height: 16),
                ],
                TextField(
                  key: const Key('login_email_field'),
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const <String>[AutofillHints.username],
                  enabled: !_submitting,
                  decoration: const InputDecoration(
                    labelText: 'Email',
                    border: OutlineInputBorder(),
                  ),
                  style: const TextStyle(color: Colors.white),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('login_password_field'),
                  controller: _passwordController,
                  obscureText: true,
                  autofillHints: const <String>[AutofillHints.password],
                  enabled: !_submitting,
                  onSubmitted: (_) => _submit(),
                  decoration: const InputDecoration(
                    labelText: 'Password',
                    border: OutlineInputBorder(),
                  ),
                  style: const TextStyle(color: Colors.white),
                ),
                const SizedBox(height: 20),
                FilledButton(
                  key: const Key('login_submit_button'),
                  onPressed: _submitting ? null : _submit,
                  child: _submitting
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Sign in'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('login_error_banner'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0x33B00020),
        border: Border.all(color: const Color(0xFFB00020)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        message,
        style: const TextStyle(color: Colors.white),
      ),
    );
  }
}
