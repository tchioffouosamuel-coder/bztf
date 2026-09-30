/// Membre du personnel, géré depuis le poste Windows et reçu par
/// synchronisation. Son badge RFID (EPC « BCM » 3) est distinct des livres
/// et des cartes d'abonné.
class StaffMember {
  const StaffMember({
    required this.id,
    required this.serverId,
    required this.staffNumber,
    required this.name,
    this.position = '',
    this.active = true,
    this.badgeEpc,
    this.badgeTid,
  });

  final int id;
  final String serverId;
  final String staffNumber;
  final String name;
  final String position;
  final bool active;
  final String? badgeEpc;
  final String? badgeTid;

  factory StaffMember.fromMap(Map<String, Object?> map) => StaffMember(
    id: map['id'] as int,
    serverId: map['server_id'] as String,
    staffNumber: map['staff_number'] as String? ?? '',
    name: map['name'] as String? ?? '',
    position: map['position'] as String? ?? '',
    active: (map['active'] as num?)?.toInt() != 0,
    badgeEpc: map['badge_epc'] as String?,
    badgeTid: map['badge_tid'] as String?,
  );
}

/// Sens d'un passage au portail.
enum PassageDirection {
  entry('in'),
  exit('out');

  const PassageDirection(this.code);

  final String code;

  static PassageDirection fromCode(String? code) =>
      code == 'out' ? PassageDirection.exit : PassageDirection.entry;

  PassageDirection get opposite => this == PassageDirection.entry
      ? PassageDirection.exit
      : PassageDirection.entry;
}

/// Passage d'un membre du personnel au portail antivol.
class StaffPassage {
  const StaffPassage({
    required this.serverId,
    required this.staffServerId,
    required this.staffNumber,
    required this.staffName,
    required this.direction,
    required this.passedAt,
    this.gateId = '',
    this.gateName = '',
  });

  final String serverId;
  final String staffServerId;
  final String staffNumber;
  final String staffName;
  final PassageDirection direction;
  final DateTime passedAt;
  final String gateId;
  final String gateName;

  factory StaffPassage.fromMap(Map<String, Object?> map) => StaffPassage(
    serverId: map['server_id'] as String,
    staffServerId: map['staff_server_id'] as String,
    staffNumber: map['staff_number'] as String? ?? '',
    staffName: map['staff_name'] as String? ?? '',
    direction: PassageDirection.fromCode(map['direction'] as String?),
    passedAt: DateTime.parse(map['passed_at'] as String).toLocal(),
    gateId: map['gate_id'] as String? ?? '',
    gateName: map['gate_name'] as String? ?? '',
  );

  Map<String, Object?> toSyncJson() => {
    'serverId': serverId,
    'staffServerId': staffServerId,
    'staffNumber': staffNumber,
    'staffName': staffName,
    'direction': direction.code,
    'passedAt': passedAt.toUtc().toIso8601String(),
    'gateId': gateId,
    'gateName': gateName,
    'createdAt': passedAt.toUtc().toIso8601String(),
  };
}

/// Compteurs d'un portail pour une journée locale.
class GateDayCounts {
  const GateDayCounts({
    required this.day,
    this.entries = 0,
    this.exits = 0,
    this.alarms = 0,
  });

  /// Jour local `AAAA-MM-JJ`.
  final String day;
  final int entries;
  final int exits;
  final int alarms;

  /// Personnes encore à l'intérieur d'après les compteurs.
  int get inside => entries > exits ? entries - exits : 0;

  factory GateDayCounts.fromMap(Map<String, Object?> map) => GateDayCounts(
    day: map['day'] as String,
    entries: (map['entries'] as num?)?.toInt() ?? 0,
    exits: (map['exits'] as num?)?.toInt() ?? 0,
    alarms: (map['alarms'] as num?)?.toInt() ?? 0,
  );

  static String dayOf(DateTime date) {
    final local = date.toLocal();
    return '${local.year.toString().padLeft(4, '0')}-'
        '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
  }
}
