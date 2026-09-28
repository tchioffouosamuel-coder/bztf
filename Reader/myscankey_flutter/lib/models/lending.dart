/// Abonné de la bibliothèque (personne autorisée à emprunter).
class Subscriber {
  const Subscriber({
    required this.id,
    required this.memberNumber,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    this.email = '',
    this.phone = '',
    this.active = true,
    this.subscriptionEndsAt,
    this.activeLoans = 0,
    this.cardEpc,
    this.cardTid,
    this.cardTaggedAt,
  });

  final int id;
  final String memberNumber;
  final String name;
  final String email;
  final String phone;
  final bool active;
  final String createdAt;
  final String updatedAt;

  /// Fin de l'abonnement actif le plus récent (calculée par la requête).
  final String? subscriptionEndsAt;

  /// Nombre d'emprunts non rendus (calculé par la requête).
  final int activeLoans;

  /// EPC réservé à la carte RFID de l'abonné (format « BCM » 2).
  final String? cardEpc;

  /// TID de la carte physique, renseigné une fois la carte encodée.
  final String? cardTid;
  final String? cardTaggedAt;

  bool get hasCard => cardTid != null && cardTid!.isNotEmpty;

  factory Subscriber.fromMap(Map<String, Object?> map) => Subscriber(
    id: map['id'] as int,
    memberNumber: map['member_number'] as String,
    name: map['name'] as String,
    email: map['email'] as String? ?? '',
    phone: map['phone'] as String? ?? '',
    active: (map['active'] as num?)?.toInt() != 0,
    createdAt: map['created_at'] as String,
    updatedAt: map['updated_at'] as String,
    subscriptionEndsAt: map['subscription_ends_at'] as String?,
    activeLoans: (map['active_loans'] as num?)?.toInt() ?? 0,
    cardEpc: map['card_epc'] as String?,
    cardTid: map['card_tid'] as String?,
    cardTaggedAt: map['card_tagged_at'] as String?,
  );

  Map<String, Object?> toMap() => {
    'id': id,
    'member_number': memberNumber,
    'name': name,
    'email': email,
    'phone': phone,
    'active': active ? 1 : 0,
    'created_at': createdAt,
    'updated_at': updatedAt,
    'card_epc': cardEpc,
    'card_tid': cardTid,
    'card_tagged_at': cardTaggedAt,
  };
}

/// Période pendant laquelle un abonné a le droit d'emprunter.
class Subscription {
  const Subscription({
    required this.id,
    required this.subscriberId,
    required this.startsAt,
    required this.endsAt,
    required this.createdAt,
    required this.updatedAt,
    this.status = 'active',
  });

  static const statuses = ['active', 'expired', 'suspended'];

  final int id;
  final int subscriberId;
  final String startsAt;
  final String endsAt;
  final String status;
  final String createdAt;
  final String updatedAt;

  bool isValidAt(DateTime date) =>
      status == 'active' && !DateTime.parse(endsAt).isBefore(date);

  factory Subscription.fromMap(Map<String, Object?> map) => Subscription(
    id: map['id'] as int,
    subscriberId: map['subscriber_id'] as int,
    startsAt: map['starts_at'] as String,
    endsAt: map['ends_at'] as String,
    status: map['status'] as String? ?? 'active',
    createdAt: map['created_at'] as String,
    updatedAt: map['updated_at'] as String,
  );

  Map<String, Object?> toMap() => {
    'id': id,
    'subscriber_id': subscriberId,
    'starts_at': startsAt,
    'ends_at': endsAt,
    'status': status,
    'created_at': createdAt,
    'updated_at': updatedAt,
  };
}

/// Emprunt d'un livre par un abonné.
class Loan {
  const Loan({
    required this.id,
    required this.bookId,
    required this.subscriberId,
    required this.borrowedAt,
    required this.dueAt,
    required this.createdAt,
    required this.updatedAt,
    this.subscriptionId,
    this.returnedAt,
    this.status = 'active',
    this.notes = '',
    this.memberNumber,
    this.subscriberName,
    this.subscriberEmail,
    this.subscriberPhone,
    this.subscriptionEndsAt,
  });

  static const statuses = ['active', 'returned', 'late'];

  final int id;
  final int bookId;
  final int subscriberId;
  final int? subscriptionId;
  final String borrowedAt;
  final String dueAt;
  final String? returnedAt;
  final String status;
  final String notes;
  final String createdAt;
  final String updatedAt;

  // Champs joints depuis l'abonné / l'abonnement (optionnels).
  final String? memberNumber;
  final String? subscriberName;
  final String? subscriberEmail;
  final String? subscriberPhone;
  final String? subscriptionEndsAt;

  bool get returned => returnedAt != null;
  bool get overdue =>
      !returned && DateTime.parse(dueAt).isBefore(DateTime.now().toUtc());

  factory Loan.fromMap(Map<String, Object?> map) => Loan(
    id: map['id'] as int,
    bookId: map['book_id'] as int,
    subscriberId: map['subscriber_id'] as int,
    subscriptionId: map['subscription_id'] as int?,
    borrowedAt: map['borrowed_at'] as String,
    dueAt: map['due_at'] as String,
    returnedAt: map['returned_at'] as String?,
    status: map['status'] as String? ?? 'active',
    notes: map['notes'] as String? ?? '',
    createdAt: map['created_at'] as String,
    updatedAt: map['updated_at'] as String,
    memberNumber: map['member_number'] as String?,
    subscriberName: map['subscriber_name'] as String?,
    subscriberEmail: map['subscriber_email'] as String?,
    subscriberPhone: map['subscriber_phone'] as String?,
    subscriptionEndsAt: map['subscription_ends_at'] as String?,
  );

  Map<String, Object?> toMap() => {
    'id': id,
    'book_id': bookId,
    'subscriber_id': subscriberId,
    'subscription_id': subscriptionId,
    'borrowed_at': borrowedAt,
    'due_at': dueAt,
    'returned_at': returnedAt,
    'status': status,
    'notes': notes,
    'created_at': createdAt,
    'updated_at': updatedAt,
  };
}
