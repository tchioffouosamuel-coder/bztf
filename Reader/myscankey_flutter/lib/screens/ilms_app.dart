import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../data/ilms_circulation_journal.dart';
import '../services/ilms_auth_service.dart';
import '../services/ilms_circulation_sync.dart';
import 'ilms_circulation_screen.dart';
import 'ilms_messages.dart';

/// Build-time defaults, mirroring the ILMS portal's `environment.ts`: the
/// gateway and its OAuth client are deployment settings, not operator secrets.
/// The portal ships the same pair in its public JS bundle, so prompting for
/// them adds friction without adding confidentiality. Override per build with
/// `--dart-define=ILMS_GATEWAY_URL=... --dart-define=ILMS_CLIENT_ID=...
/// --dart-define=ILMS_CLIENT_SECRET=...`, or per session from the login form.
const ilmsDefaultGatewayUrl = String.fromEnvironment(
  'ILMS_GATEWAY_URL',
  defaultValue: 'https://gateway.bibliotheque-ztf.org',
);
const ilmsDefaultClientId = String.fromEnvironment(
  'ILMS_CLIENT_ID',
  defaultValue: 'test-client',
);
const ilmsDefaultClientSecret = String.fromEnvironment(
  'ILMS_CLIENT_SECRET',
  defaultValue: 'secret',
);

ThemeData ilmsTheme() {
  final theme = ThemeData(
    useMaterial3: true,
    fontFamily: 'Montserrat',
    colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0B659E)),
    scaffoldBackgroundColor: const Color(0xFFF4F7FA),
    inputDecorationTheme: const InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
      ),
    ),
  );
  const spacing = TextTheme(
    displayLarge: TextStyle(letterSpacing: 0),
    displayMedium: TextStyle(letterSpacing: 0),
    displaySmall: TextStyle(letterSpacing: 0),
    headlineLarge: TextStyle(letterSpacing: 0),
    headlineMedium: TextStyle(letterSpacing: 0),
    headlineSmall: TextStyle(letterSpacing: 0),
    titleLarge: TextStyle(letterSpacing: 0),
    titleMedium: TextStyle(letterSpacing: 0),
    titleSmall: TextStyle(letterSpacing: 0),
    bodyLarge: TextStyle(letterSpacing: 0),
    bodyMedium: TextStyle(letterSpacing: 0),
    bodySmall: TextStyle(letterSpacing: 0),
    labelLarge: TextStyle(letterSpacing: 0),
    labelMedium: TextStyle(letterSpacing: 0),
    labelSmall: TextStyle(letterSpacing: 0),
  );
  return theme.copyWith(
    textTheme: theme.textTheme.merge(spacing),
    primaryTextTheme: theme.primaryTextTheme.merge(spacing),
  );
}

class IlmsApp extends StatefulWidget {
  const IlmsApp({
    super.key,
    this.auth,
    this.openJournal,
    this.circulationClient,
  });
  final IlmsAuthService? auth;
  final Future<IlmsCirculationJournal> Function()? openJournal;
  final http.Client? circulationClient;

  @override
  State<IlmsApp> createState() => _IlmsAppState();
}

class _IlmsAppState extends State<IlmsApp> {
  late final IlmsAuthService _auth = widget.auth ?? IlmsAuthService();

  @override
  void dispose() {
    if (widget.auth == null) _auth.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'BIBLIORFID - ILMS',
    debugShowCheckedModeBanner: false,
    theme: ilmsTheme(),
    home: AnimatedBuilder(
      animation: _auth,
      builder: (context, _) {
        if (!_auth.signedIn) return IlmsLoginScreen(auth: _auth);
        final session = _auth.session;
        return Scaffold(
          appBar: AppBar(
            title: const Text('BIBLIORFID', style: TextStyle(fontSize: 18)),
            actions: [
              IconButton(
                tooltip: 'Deconnexion',
                onPressed: _auth.logout,
                icon: const Icon(Icons.logout),
              ),
            ],
          ),
          body: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: DropdownButtonFormField<String>(
                  key: ValueKey(session?.libraryId),
                  initialValue: session?.libraryId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Bibliotheque ILMS',
                  ),
                  items: _auth.libraries
                      .map(
                        (library) => DropdownMenuItem(
                          value: library.id,
                          child: Text(
                            library.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (id) {
                    if (id != null) _auth.selectLibrary(id);
                  },
                ),
              ),
              Expanded(
                child: session == null
                    ? const Center(
                        child: Icon(Icons.local_library_outlined, size: 48),
                      )
                    : _IlmsWorkspace(
                        key: ValueKey(
                          '${session.gatewayUrl}/${session.accountId}/${session.libraryId}',
                        ),
                        auth: _auth,
                        openJournal:
                            widget.openJournal ?? IlmsCirculationJournal.open,
                        client: widget.circulationClient,
                      ),
              ),
            ],
          ),
        );
      },
    ),
  );
}

class IlmsLoginScreen extends StatefulWidget {
  const IlmsLoginScreen({super.key, required this.auth});
  final IlmsAuthService auth;
  @override
  State<IlmsLoginScreen> createState() => _IlmsLoginScreenState();
}

class _IlmsLoginScreenState extends State<IlmsLoginScreen> {
  final _form = GlobalKey<FormState>();
  final _gateway = TextEditingController(text: ilmsDefaultGatewayUrl);
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _clientId = TextEditingController(text: ilmsDefaultClientId);
  final _secret = TextEditingController(text: ilmsDefaultClientSecret);
  bool _busy = false;
  bool _hidden = true;
  // Only revealed on demand, or when the build ships no usable client.
  bool _advanced =
      ilmsDefaultClientId.isEmpty || ilmsDefaultClientSecret.isEmpty;
  String? _error;

  @override
  void dispose() {
    for (final controller in [
      _gateway,
      _username,
      _password,
      _clientId,
      _secret,
    ]) {
      controller.clear();
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _login() async {
    if (_busy || !_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.auth.signIn(
        gatewayUrl: _gateway.text,
        username: _username.text,
        password: _password.text,
        clientId: _clientId.text,
        clientSecret: _secret.text,
      );
    } catch (error) {
      if (mounted) setState(() => _error = ilmsErrorMessage(error));
    } finally {
      if (mounted) {
        _password.clear();
        // Discards an operator-typed secret; the build default is already in
        // the binary, so restoring it leaks nothing and keeps the form usable.
        _secret.text = ilmsDefaultClientSecret;
        setState(() => _busy = false);
      }
    }
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    bool secret = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextFormField(
      controller: controller,
      enabled: !_busy,
      obscureText: secret,
      autocorrect: false,
      enableSuggestions: false,
      validator: (value) =>
          value == null || value.isEmpty ? 'Champ requis' : null,
      decoration: InputDecoration(labelText: label),
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Form(
              key: _form,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Align(
                    child: Image.asset(
                      'assets/images/bibliorfid-logo.jpg',
                      width: 72,
                      height: 72,
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'BIBLIORFID',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
                  ),
                  const Text('Connexion ILMS', textAlign: TextAlign.center),
                  const SizedBox(height: 24),
                  _field(_gateway, 'Gateway ILMS'),
                  _field(_username, 'Identifiant ILMS'),
                  TextFormField(
                    controller: _password,
                    enabled: !_busy,
                    obscureText: _hidden,
                    autocorrect: false,
                    enableSuggestions: false,
                    validator: (value) =>
                        value == null || value.isEmpty ? 'Champ requis' : null,
                    decoration: InputDecoration(
                      labelText: 'Mot de passe',
                      suffixIcon: IconButton(
                        tooltip: _hidden
                            ? 'Afficher le mot de passe'
                            : 'Masquer le mot de passe',
                        onPressed: _busy
                            ? null
                            : () => setState(() => _hidden = !_hidden),
                        icon: Icon(
                          _hidden
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: _busy
                          ? null
                          : () => setState(() => _advanced = !_advanced),
                      icon: Icon(
                        _advanced ? Icons.expand_less : Icons.expand_more,
                      ),
                      label: const Text('Parametres avances'),
                    ),
                  ),
                  if (_advanced) ...[
                    const SizedBox(height: 12),
                    _field(_clientId, 'Client OAuth'),
                    _field(_secret, 'Secret du client OAuth', secret: true),
                  ],
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  FilledButton.icon(
                    onPressed: _busy ? null : _login,
                    icon: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.login),
                    label: const Text('Se connecter'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _IlmsWorkspace extends StatefulWidget {
  const _IlmsWorkspace({
    super.key,
    required this.auth,
    required this.openJournal,
    this.client,
  });
  final IlmsAuthService auth;
  final Future<IlmsCirculationJournal> Function() openJournal;
  final http.Client? client;
  @override
  State<_IlmsWorkspace> createState() => _IlmsWorkspaceState();
}

class _IlmsWorkspaceState extends State<_IlmsWorkspace> {
  IlmsCirculationJournal? _journal;
  IlmsCirculationSync? _sync;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    setState(() => _error = null);
    try {
      final journal = await widget.openJournal();
      if (!mounted) {
        await journal.close();
        return;
      }
      _journal = journal;
      setState(
        () => _sync = IlmsCirculationSync(
          journal: journal,
          getSession: () => widget.auth.session,
          client: widget.client,
        ),
      );
    } catch (error) {
      if (mounted) setState(() => _error = ilmsErrorMessage(error));
    }
  }

  @override
  void dispose() {
    _sync?.close();
    if (_journal != null) unawaited(_journal!.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_sync != null) return IlmsCirculationScreen(sync: _sync!);
    if (_error == null) return const Center(child: CircularProgressIndicator());
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _open,
              icon: const Icon(Icons.refresh),
              label: const Text('Reessayer'),
            ),
          ],
        ),
      ),
    );
  }
}
