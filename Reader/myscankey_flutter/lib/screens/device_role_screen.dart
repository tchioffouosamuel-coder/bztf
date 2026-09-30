import 'package:flutter/material.dart';

import '../app.dart';
import '../services/kiosk_controller.dart';
import '../services/library_controller.dart';

/// Première ouverture : l'appareil devient un poste d'emprunt en
/// libre-service, un lecteur mobile pour le personnel ou le portail antivol.
class DeviceRoleScreen extends StatefulWidget {
  const DeviceRoleScreen({required this.controller, super.key});

  final LibraryController controller;

  @override
  State<DeviceRoleScreen> createState() => _DeviceRoleScreenState();
}

class _DeviceRoleScreenState extends State<DeviceRoleScreen> {
  bool _saving = false;

  Future<void> _choose(String role) async {
    setState(() => _saving = true);
    try {
      await widget.controller.setDeviceRole(role);
    } catch (error) {
      if (mounted) showMessage(context, error.toString(), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1060),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.all(24),
              children: [
                Center(
                  child: Image.asset(
                    'assets/images/bibliorfid-logo.jpg',
                    height: 72,
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  'Bibliothèque ZTF',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Comment cet appareil sera-t-il utilisé ?',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyLarge,
                ),
                const SizedBox(height: 24),
                Wrap(
                  spacing: 14,
                  runSpacing: 14,
                  alignment: WrapAlignment.center,
                  children: [
                    _RoleCard(
                      icon: Icons.point_of_sale_outlined,
                      title: 'Poste d’emprunt',
                      description:
                          'Tablette fixe reliée au lecteur RFID de bureau. '
                          'Les abonnés y posent leur carte et leurs livres pour '
                          'emprunter ou rendre en libre-service.',
                      onTap: _saving ? null : () => _choose('kiosk'),
                    ),
                    _RoleCard(
                      icon: Icons.phone_android_outlined,
                      title: 'Lecteur mobile',
                      description:
                          'Terminal du personnel avec lecteur UHF intégré : '
                          'catalogue, encodage des tags, inventaire, '
                          'localisation et prêts au comptoir.',
                      onTap: _saving ? null : () => _choose('mobile'),
                    ),
                    _RoleCard(
                      icon: Icons.shield_outlined,
                      title: 'Portail antivol',
                      description:
                          'Tablette reliée au portail RFID N01 de la sortie : '
                          'alarme vocale si un livre non emprunté passe, '
                          'comptage des entrées et sorties, passages du '
                          'personnel par badge.',
                      onTap: _saving ? null : () => _choose('gate'),
                    ),
                  ],
                ),
                const SizedBox(height: 22),
                Text(
                  'Code administrateur initial du poste : '
                  '${KioskController.defaultPin}. Changez-le dans le terminal '
                  'admin. Le type d’appareil reste modifiable dans les réglages.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RoleCard extends StatelessWidget {
  const _RoleCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String description;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: 320,
      child: Card(
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: colors.outlineVariant),
        ),
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 26,
                  backgroundColor: colors.primaryContainer,
                  child: Icon(icon, color: colors.primary, size: 28),
                ),
                const SizedBox(height: 14),
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                Text(description),
                const SizedBox(height: 14),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.tonal(
                    onPressed: onTap,
                    child: const Text('Choisir'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
