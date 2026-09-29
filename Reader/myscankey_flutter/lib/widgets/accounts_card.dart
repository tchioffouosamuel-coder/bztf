import 'package:flutter/material.dart';

import '../app.dart';
import '../models/user.dart';
import '../services/library_controller.dart';

/// Compte connecté et, pour un administrateur, gestion des comptes.
class AccountsCard extends StatefulWidget {
  const AccountsCard({required this.controller, super.key});

  final LibraryController controller;

  @override
  State<AccountsCard> createState() => _AccountsCardState();
}

class _AccountsCardState extends State<AccountsCard> {
  List<AppUser> _users = const [];

  LibraryController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (controller.currentUser?.isAdmin != true) return;
    final users = await controller.database.listUsers();
    if (mounted) setState(() => _users = users);
  }

  String _describe(Object error) => error.toString().replaceFirst(
    RegExp(r'^(Bad state|Invalid argument\(s\)):?\s*'),
    '',
  );

  Future<void> _signOut() async {
    final confirmed = await confirmAction(
      context,
      title: 'Se déconnecter ?',
      message: 'L’application reviendra à l’écran de connexion.',
      confirmLabel: 'Déconnecter',
    );
    if (!confirmed || !mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
    await controller.signOut();
  }

  Future<void> _changePassword() async {
    final current = TextEditingController();
    final next = TextEditingController();
    final confirm = TextEditingController();
    final saved = await _formDialog(
      title: 'Changer le mot de passe',
      fields: [
        _field(current, 'Mot de passe actuel', obscure: true),
        _field(next, 'Nouveau mot de passe (8 caractères min.)', obscure: true),
        _field(confirm, 'Confirmer', obscure: true),
      ],
      onSave: () async {
        if (next.text != confirm.text) {
          throw StateError('Les mots de passe ne correspondent pas.');
        }
        await controller.database.changePassword(
          controller.currentUser!.id,
          current: current.text,
          next: next.text,
        );
      },
    );
    for (final field in [current, next, confirm]) {
      field.dispose();
    }
    if (saved && mounted) showMessage(context, 'Mot de passe modifié.');
  }

  Future<void> _addUser() async {
    final name = TextEditingController();
    final email = TextEditingController();
    final password = TextEditingController();
    var admin = false;
    final saved = await _formDialog(
      title: 'Nouveau compte',
      fields: [
        _field(name, 'Nom'),
        _field(email, 'E-mail', keyboard: TextInputType.emailAddress),
        _field(password, 'Mot de passe (8 caractères min.)', obscure: true),
        StatefulBuilder(
          builder: (context, setDialogState) => SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Administrateur'),
            value: admin,
            onChanged: (value) => setDialogState(() => admin = value),
          ),
        ),
      ],
      onSave: () async {
        await controller.database.createUser(
          name: name.text,
          email: email.text,
          password: password.text,
          role: admin ? 'admin' : 'operateur',
        );
      },
    );
    for (final field in [name, email, password]) {
      field.dispose();
    }
    if (saved) await _load();
  }

  Future<void> _toggle(AppUser user) async {
    try {
      await controller.database.setUserActive(user.id, !user.active);
      await _load();
    } catch (error) {
      if (mounted) showMessage(context, _describe(error), error: true);
    }
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    bool obscure = false,
    TextInputType? keyboard,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: TextField(
      controller: controller,
      obscureText: obscure,
      keyboardType: keyboard,
      autocorrect: false,
      decoration: InputDecoration(labelText: label),
    ),
  );

  Future<bool> _formDialog({
    required String title,
    required List<Widget> fields,
    required Future<void> Function() onSave,
  }) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) {
          String? error;
          var busy = false;
          return StatefulBuilder(
            builder: (context, setDialogState) => AlertDialog(
              title: Text(title),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ...fields,
                    if (error != null)
                      Text(
                        error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Annuler'),
                ),
                FilledButton(
                  onPressed: busy
                      ? null
                      : () async {
                          setDialogState(() {
                            busy = true;
                            error = null;
                          });
                          try {
                            await onSave();
                            if (context.mounted) Navigator.pop(context, true);
                          } catch (exception) {
                            setDialogState(() {
                              busy = false;
                              error = _describe(exception);
                            });
                          }
                        },
                  child: const Text('Enregistrer'),
                ),
              ],
            ),
          );
        },
      ) ??
      false;

  @override
  Widget build(BuildContext context) {
    final user = controller.currentUser;
    if (user == null) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    return Card(
      child: Column(
        children: [
          ListTile(
            leading: CircleAvatar(
              backgroundColor: colors.primaryContainer,
              child: Icon(
                user.isAdmin
                    ? Icons.admin_panel_settings_outlined
                    : Icons.person_outline,
                color: colors.primary,
              ),
            ),
            title: Text(user.name),
            subtitle: Text(
              '${user.email} · ${user.isAdmin ? 'Administrateur' : 'Opérateur'}',
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _changePassword,
                  icon: const Icon(Icons.password),
                  label: const Text('Mot de passe'),
                ),
                OutlinedButton.icon(
                  onPressed: _signOut,
                  icon: const Icon(Icons.logout),
                  label: const Text('Se déconnecter'),
                ),
              ],
            ),
          ),
          if (user.isAdmin) ...[
            const Divider(height: 1),
            ListTile(
              title: const Text(
                'Comptes de l’appareil',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              trailing: TextButton.icon(
                onPressed: _addUser,
                icon: const Icon(Icons.person_add_alt),
                label: const Text('Ajouter'),
              ),
            ),
            for (final account in _users)
              SwitchListTile(
                secondary: Icon(
                  account.isAdmin
                      ? Icons.admin_panel_settings_outlined
                      : Icons.person_outline,
                ),
                title: Text(account.name),
                subtitle: Text(
                  '${account.email} · '
                  '${account.isAdmin ? 'Administrateur' : 'Opérateur'}',
                ),
                value: account.active,
                onChanged: account.id == user.id
                    ? null
                    : (_) => _toggle(account),
              ),
          ],
        ],
      ),
    );
  }
}
