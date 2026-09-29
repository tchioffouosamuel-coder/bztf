import 'package:flutter/material.dart';

import '../services/library_controller.dart';

/// Identification à l'ouverture. Sans compte sur l'appareil, crée
/// l'administrateur (même règle que l'application Windows).
class LoginScreen extends StatefulWidget {
  const LoginScreen({required this.controller, super.key});

  final LibraryController controller;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  bool _obscure = true;
  String? _error;

  bool get _setup => !widget.controller.hasAccounts;

  @override
  void dispose() {
    for (final field in [_name, _email, _password, _confirm]) {
      field.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_setup) {
        await widget.controller.createFirstAdmin(
          name: _name.text,
          email: _email.text,
          password: _password.text,
        );
      } else {
        await widget.controller.signIn(_email.text, _password.text);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString().replaceFirst(
          RegExp(r'^(Bad state|Invalid argument\(s\)):?\s*'),
          '',
        );
        _password.clear();
        _confirm.clear();
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String? _required(String? value, String message) =>
      value == null || value.trim().isEmpty ? message : null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _formKey,
                child: AutofillGroup(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: Image.asset(
                          'assets/images/bibliorfid-logo.jpg',
                          height: 72,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Bibliothèque ZTF',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _setup
                            ? 'Créez le compte administrateur de cet appareil.'
                            : 'Identifiez-vous pour ouvrir l’application.',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 24),
                      if (_setup) ...[
                        TextFormField(
                          controller: _name,
                          textCapitalization: TextCapitalization.words,
                          autofillHints: const [AutofillHints.name],
                          decoration: const InputDecoration(
                            labelText: 'Nom',
                            prefixIcon: Icon(Icons.person_outline),
                          ),
                          validator: (value) => (value ?? '').trim().length < 2
                              ? 'Le nom doit contenir au moins 2 caractères.'
                              : null,
                        ),
                        const SizedBox(height: 12),
                      ],
                      TextFormField(
                        controller: _email,
                        keyboardType: TextInputType.emailAddress,
                        autocorrect: false,
                        autofillHints: const [AutofillHints.email],
                        decoration: const InputDecoration(
                          labelText: 'E-mail',
                          prefixIcon: Icon(Icons.alternate_email),
                        ),
                        validator: (value) =>
                            _required(value, 'L’e-mail est obligatoire.'),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _password,
                        obscureText: _obscure,
                        autofillHints: [
                          _setup
                              ? AutofillHints.newPassword
                              : AutofillHints.password,
                        ],
                        decoration: InputDecoration(
                          labelText: 'Mot de passe',
                          prefixIcon: const Icon(Icons.lock_outline),
                          suffixIcon: IconButton(
                            tooltip: _obscure ? 'Afficher' : 'Masquer',
                            onPressed: () =>
                                setState(() => _obscure = !_obscure),
                            icon: Icon(
                              _obscure
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                            ),
                          ),
                        ),
                        onFieldSubmitted: _setup ? null : (_) => _submit(),
                        validator: (value) {
                          if (_setup && (value ?? '').length < 8) {
                            return 'Au moins 8 caractères.';
                          }
                          return _required(
                            value,
                            'Le mot de passe est obligatoire.',
                          );
                        },
                      ),
                      if (_setup) ...[
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _confirm,
                          obscureText: _obscure,
                          decoration: const InputDecoration(
                            labelText: 'Confirmer le mot de passe',
                            prefixIcon: Icon(Icons.lock_outline),
                          ),
                          onFieldSubmitted: (_) => _submit(),
                          validator: (value) => value != _password.text
                              ? 'Les mots de passe ne correspondent pas.'
                              : null,
                        ),
                      ],
                      if (_error case final error?) ...[
                        const SizedBox(height: 14),
                        Text(
                          error,
                          textAlign: TextAlign.center,
                          style: TextStyle(color: theme.colorScheme.error),
                        ),
                      ],
                      const SizedBox(height: 20),
                      FilledButton.icon(
                        onPressed: _busy ? null : _submit,
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(0, 52),
                        ),
                        icon: _busy
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Icon(_setup ? Icons.person_add : Icons.login),
                        label: Text(
                          _setup ? 'Créer le compte' : 'Se connecter',
                        ),
                      ),
                      if (!_setup) ...[
                        const SizedBox(height: 14),
                        Text(
                          'Mot de passe oublié : un administrateur de cet '
                          'appareil peut réactiver ou recréer votre compte.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
