/// Compte du personnel autorisé à ouvrir l'application.
class AppUser {
  const AppUser({
    required this.id,
    required this.name,
    required this.email,
    required this.role,
    this.active = true,
  });

  static const roles = ['admin', 'operateur'];

  final int id;
  final String name;
  final String email;
  final String role;
  final bool active;

  bool get isAdmin => role == 'admin';

  /// Ne lit jamais l'empreinte ni le sel du mot de passe.
  factory AppUser.fromMap(Map<String, Object?> map) => AppUser(
    id: map['id'] as int,
    name: map['name'] as String,
    email: map['email'] as String,
    role: map['role'] as String,
    active: (map['active'] as num?)?.toInt() != 0,
  );
}
