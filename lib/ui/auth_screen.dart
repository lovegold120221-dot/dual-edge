import 'package:flutter/material.dart';

import '../core/app_theme.dart';
import '../state/app_controller.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({required this.controller, super.key});

  final AppController controller;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  _AuthView _view = _AuthView.signIn;
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _submitting = false;
  String? _message;
  bool _messageIsError = true;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _run(
    Future<void> Function() action, {
    String? successMessage,
  }) async {
    setState(() {
      _submitting = true;
      _message = null;
    });
    try {
      await action();
      if (!mounted) return;
      if (successMessage != null) {
        setState(() {
          _message = successMessage;
          _messageIsError = false;
        });
      }
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _message = error.toString().replaceFirst(
          RegExp(r'^(Exception|Bad state):\s*'),
          '',
        );
        _messageIsError = true;
      });
    } finally {
      if (mounted) {
        setState(() {
          _submitting = false;
        });
      }
    }
  }

  String get _title => switch (_view) {
    _AuthView.signIn => 'Sign In',
    _AuthView.signUp => 'Create account',
    _AuthView.reset => 'Reset password',
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_title)),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const SizedBox(height: 24),
            TextField(
              controller: _emailController,
              decoration: const InputDecoration(
                labelText: 'Email',
                hintText: 'you@eburon.ai',
              ),
              keyboardType: TextInputType.emailAddress,
              onChanged: (_) => setState(() {}),
            ),
            if (_view != _AuthView.reset) ...<Widget>[
              const SizedBox(height: 16),
              TextField(
                controller: _passwordController,
                decoration: const InputDecoration(
                  labelText: 'Password',
                  hintText: '••••••••',
                ),
                obscureText: true,
                onSubmitted: (_) => _submitPrimary(),
              ),
            ],
            const SizedBox(height: 24),
            if (_message != null)
              Text(
                _message!,
                style: TextStyle(
                  color: _messageIsError ? AppColors.red : AppColors.green,
                  fontSize: 12,
                ),
              ),
            if (_message != null) const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _submitting ? null : _submitPrimary,
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
                side: const BorderSide(color: AppColors.border),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              icon: Icon(
                _view == _AuthView.signUp
                    ? Icons.person_add_rounded
                    : Icons.login_rounded,
              ),
              label: Text(_title),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _submitting
                  ? null
                  : () => _run(() => widget.controller.signInWithGoogle()),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
                side: const BorderSide(color: AppColors.border),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              icon: const Text(
                'G',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: AppColors.blue,
                ),
              ),
              label: const Text('Continue with Google'),
            ),
            const SizedBox(height: 8),
            if (_view == _AuthView.signIn) ...<Widget>[
              TextButton(
                onPressed: _submitting
                    ? null
                    : () => setState(() => _view = _AuthView.signUp),
                child: const Text('New here? Create account'),
              ),
              TextButton(
                onPressed: _submitting
                    ? null
                    : () => setState(() => _view = _AuthView.reset),
                child: const Text('Forgot password?'),
              ),
            ] else ...<Widget>[
              TextButton(
                onPressed: _submitting
                    ? null
                    : () => setState(() => _view = _AuthView.signIn),
                child: const Text('Already have an account? Sign in'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _submitPrimary() {
    final email = _emailController.text;
    final password = _passwordController.text;
    return switch (_view) {
      _AuthView.signIn => _run(() => widget.controller.signIn(email, password)),
      _AuthView.signUp => _run(() => widget.controller.signUp(email, password)),
      _AuthView.reset => _run(
        () => widget.controller.sendPasswordReset(email),
        successMessage: 'Password reset email sent.',
      ),
    };
  }
}

enum _AuthView { signIn, signUp, reset }
