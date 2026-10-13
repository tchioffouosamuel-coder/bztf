import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

import '../services/ilms_circulation_client.dart';

const _applicationId = 0x494c4d53;
const _maxSafeInteger = 9007199254740991;

String newIlmsCirculationId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes
      .map((value) => value.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

List<String> _scopeValues(Map<String, String> scope) {
  final normalized = normalizeIlmsScope(
    IlmsSession(
      gatewayUrl: scope['gateway_url'] ?? '',
      accountId: scope['account_id'] ?? '',
      libraryId: scope['library_id'] ?? '',
      accessToken: '',
    ),
  );
  return [
    normalized['gateway_url']!,
    normalized['account_id']!,
    normalized['library_id']!,
  ];
}

String _signature(Map<String, Object?> operation) {
  final payload = Map<String, Object?>.from(operation['payload'] as Map);
  if (operation['kind'] == 'checkout') payload.remove('operation_id');
  return sha256
      .convert(
        utf8.encode(
          jsonEncode({'kind': operation['kind'], 'payload': payload}),
        ),
      )
      .toString();
}

/// A separate native intent store. Never adopts the legacy catalogue database.
class IlmsCirculationJournal {
  IlmsCirculationJournal._(this._database, this._now);
  final Database _database;
  final DateTime Function() _now;

  static Future<IlmsCirculationJournal> open({
    String? filePath,
    DatabaseFactory? factory,
    DateTime Function()? now,
  }) async {
    Database? database;
    try {
      final provider = factory ?? databaseFactory;
      final file =
          filePath ??
          path.join(await provider.getDatabasesPath(), 'ilms_circulation.db');
      if (file.isEmpty || file == inMemoryDatabasePath) {
        throw const IlmsClientException('storage');
      }
      database = await provider.openDatabase(
        file,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      await database.rawQuery('PRAGMA busy_timeout = 5000');
      await database.transaction((transaction) async {
        final owner = (await transaction.rawQuery(
          'PRAGMA application_id',
        )).single['application_id'];
        final version = (await transaction.rawQuery(
          'PRAGMA user_version',
        )).single['user_version'];
        final objects = await transaction.rawQuery(
          "SELECT type, name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'",
        );
        var businessObjects = objects.length;
        // SQLiteDatabase creates this locale table even in a brand-new Android
        // database. Ignore only its exact native shape, never a business table.
        if (Platform.isAndroid && owner == 0) {
          final metadata = objects.where(
            (row) => row['name'] == 'android_metadata',
          );
          if (metadata.isNotEmpty) {
            final columns = await transaction.rawQuery(
              'PRAGMA table_info(android_metadata)',
            );
            if (metadata.single['type'] != 'table' ||
                columns.length != 1 ||
                columns.single['name'] != 'locale' ||
                columns.single['type'] != 'TEXT' ||
                columns.single['pk'] != 0 ||
                columns.single['notnull'] != 0 ||
                columns.single['dflt_value'] != null) {
              throw const IlmsClientException('storage');
            }
            businessObjects--;
          }
        }
        if ((owner != 0 && owner != _applicationId) ||
            (owner == 0 && (businessObjects != 0 || version != 0)) ||
            (owner == _applicationId && version != 1)) {
          throw const IlmsClientException('storage');
        }
        if (owner == 0) {
          await transaction.execute('''CREATE TABLE operations (
            id TEXT PRIMARY KEY, gateway_url TEXT NOT NULL, account_id TEXT NOT NULL, library_id TEXT NOT NULL,
            kind TEXT NOT NULL CHECK(kind IN ('checkout', 'return')), payload TEXT NOT NULL, signature TEXT NOT NULL,
            created_at TEXT NOT NULL, updated_at TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0,
            last_status INTEGER, state TEXT NOT NULL DEFAULT 'pending' CHECK(state IN ('pending', 'blocked')),
            lease_id TEXT, lease_until INTEGER NOT NULL DEFAULT 0,
            UNIQUE(gateway_url, account_id, library_id, signature)
          )''');
          await transaction.execute(
            'CREATE INDEX operations_scope ON operations(gateway_url, account_id, library_id)',
          );
          await transaction.execute('PRAGMA application_id = $_applicationId');
          await transaction.execute('PRAGMA user_version = 1');
        }
        await transaction.rawQuery(
          'SELECT id, gateway_url, account_id, library_id, kind, payload, signature, created_at, updated_at, attempts, last_status, state, lease_id, lease_until FROM operations LIMIT 0',
        );
      }, exclusive: true);
      final mode = (await database.rawQuery(
        'PRAGMA journal_mode = WAL',
      )).single['journal_mode'];
      await database.execute('PRAGMA synchronous = FULL');
      final durability = (await database.rawQuery(
        'PRAGMA synchronous',
      )).single['synchronous'];
      if (mode != 'wal' || durability != 2) {
        throw const IlmsClientException('storage');
      }
      return IlmsCirculationJournal._(database, now ?? DateTime.now);
    } catch (_) {
      try {
        await database?.close();
      } catch (_) {}
      throw const IlmsClientException('storage');
    }
  }

  Future<T> _safe<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on IlmsClientException {
      rethrow;
    } catch (_) {
      throw const IlmsClientException('storage');
    }
  }

  Future<T> _transaction<T>(Future<T> Function(Transaction) action) =>
      _safe(() => _database.transaction(action, exclusive: true));

  Future<List<Map<String, Object?>>> _list(
    DatabaseExecutor database,
    Map<String, String> scope,
  ) async {
    final rows = await database.rawQuery(
      'SELECT * FROM operations WHERE gateway_url = ? AND account_id = ? AND library_id = ? ORDER BY created_at, rowid',
      _scopeValues(scope),
    );
    return rows.map(_entry).toList();
  }

  Future<List<Map<String, Object?>>> list(Map<String, String> scope) =>
      _safe(() => _list(_database, scope));

  Future<Map<String, Object?>> enqueue(
    Map<String, String> scope,
    Object? input,
  ) async {
    final operation = normalizeIlmsOperation(input);
    final signature = _signature(operation);
    final values = _scopeValues(scope);
    return _transaction((transaction) async {
      final entries = await _list(transaction, scope);
      for (final entry in entries) {
        if (_signature(entry) == signature) return entry;
      }
      if (entries.length >= 100) throw const IlmsClientException('capacity');
      final id = operation['kind'] == 'checkout'
          ? (operation['payload'] as Map)['operation_id'] as String
          : newIlmsCirculationId();
      final date = _date();
      await transaction.rawInsert(
        'INSERT INTO operations(id, gateway_url, account_id, library_id, kind, payload, signature, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          id,
          ...values,
          operation['kind'],
          jsonEncode(operation['payload']),
          signature,
          date,
          date,
        ],
      );
      return _find(transaction, scope, id);
    });
  }

  Future<Map<String, Object?>> claim(
    Map<String, String> scope,
    String id,
    String lease,
  ) async {
    lease = normalizeIlmsUuid(lease);
    return _transaction((transaction) async {
      final entry = await _find(transaction, scope, id);
      final now = _milliseconds();
      if ((entry['lease_until'] as int) > now) {
        throw const IlmsClientException('busy');
      }
      await transaction.rawUpdate(
        'UPDATE operations SET lease_id = ?, lease_until = ?, attempts = attempts + 1, updated_at = ? WHERE id = ?',
        [lease, now + 120000, _date(), entry['id']],
      );
      return _find(transaction, scope, id);
    });
  }

  Future<void> failed(
    Map<String, String> scope,
    String id,
    String lease,
    int status,
  ) async {
    if (status < 0 || status > 599) throw const IlmsClientException('input');
    return _transaction((transaction) async {
      final entry = await _find(transaction, scope, id);
      if (entry['lease_id'] != lease) throw const IlmsClientException('busy');
      final blocked =
          status >= 400 && status < 500 && ![408, 425, 429].contains(status);
      await transaction.rawUpdate(
        'UPDATE operations SET lease_id = NULL, lease_until = 0, last_status = ?, state = ?, updated_at = ? WHERE id = ?',
        [status, blocked ? 'blocked' : 'pending', _date(), entry['id']],
      );
    });
  }

  Future<void> remove(Map<String, String> scope, String id, {String? lease}) =>
      _transaction((transaction) async {
        final entry = await _find(transaction, scope, id);
        if (lease != null
            ? entry['lease_id'] != lease
            : (entry['lease_until'] as int) > _milliseconds()) {
          throw const IlmsClientException('busy');
        }
        await transaction.rawDelete('DELETE FROM operations WHERE id = ?', [
          entry['id'],
        ]);
      });

  Future<Map<String, Object?>> _find(
    DatabaseExecutor database,
    Map<String, String> scope,
    String id,
  ) async {
    final canonicalId = normalizeIlmsUuid(id);
    final entries = await _list(database, scope);
    for (final entry in entries) {
      if (entry['id'] == canonicalId) return entry;
    }
    throw const IlmsClientException('scope');
  }

  Map<String, Object?> _entry(Map<String, Object?> row) {
    try {
      final operation = normalizeIlmsOperation({
        'kind': row['kind'],
        'payload': jsonDecode(row['payload'] as String),
      });
      final lease = row['lease_id'];
      final until = row['lease_until'];
      final attempts = row['attempts'];
      final status = row['last_status'];
      final id = normalizeIlmsUuid(row['id'], 'storage');
      if (row['id'] != id ||
          jsonEncode(operation['payload']) != row['payload'] ||
          _signature(operation) != row['signature'] ||
          !['pending', 'blocked'].contains(row['state']) ||
          attempts is! int ||
          attempts < 0 ||
          attempts > _maxSafeInteger ||
          until is! int ||
          until < 0 ||
          until > _maxSafeInteger ||
          (lease == null
              ? until != 0
              : normalizeIlmsUuid(lease, 'storage') != lease || until == 0) ||
          (status != null && (status is! int || status < 0 || status > 599)) ||
          row['created_at'] is! String ||
          DateTime.tryParse(row['created_at'] as String) == null ||
          row['updated_at'] is! String ||
          DateTime.tryParse(row['updated_at'] as String) == null ||
          (operation['kind'] == 'checkout' &&
              (operation['payload'] as Map)['operation_id'] != id)) {
        throw const IlmsClientException('storage');
      }
      return {
        ...operation,
        'id': id,
        'gateway_url': row['gateway_url'],
        'account_id': row['account_id'],
        'library_id': row['library_id'],
        'created_at': row['created_at'],
        'updated_at': row['updated_at'],
        'attempts': attempts,
        'last_status': status,
        'state': row['state'],
        'lease_id': lease,
        'lease_until': until,
      };
    } catch (_) {
      throw const IlmsClientException('storage');
    }
  }

  int _milliseconds() {
    final value = _now().millisecondsSinceEpoch;
    if (value < 0 || value > _maxSafeInteger - 120000) {
      throw const IlmsClientException('storage');
    }
    return value;
  }

  String _date() => DateTime.fromMillisecondsSinceEpoch(
    _milliseconds(),
    isUtc: true,
  ).toIso8601String();

  Future<void> close() => _safe(() => _database.close());
}
