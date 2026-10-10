/// Keeps the SDK snapshot intact and builds a patch of writable parameters.
class N01SettingsDraft {
  N01SettingsDraft(Map<String, Object?> snapshot) {
    values = _copy(snapshot) as Map<String, Object?>;
    final network = values['network'];
    if (network is Map && network['time'] is String) {
      final time = DateTime.tryParse(network['time'] as String);
      if (time != null) {
        network['time'] = [
          time.year,
          time.month,
          time.day,
          time.hour,
          time.minute,
          time.second,
        ];
      }
    }
    _original = _copy(values) as Map<String, Object?>;
    final reporting = values['reporting'];
    final autoInvCfg = reporting is Map ? reporting['autoInvCfg'] : null;
    if (autoInvCfg is Map) {
      // This SDK's getter omits syncinterv, although the setter requires it.
      autoInvCfg.putIfAbsent('syncinterv', () => null);
    }
  }

  late final Map<String, Object?> values;
  late final Map<String, Object?> _original;

  static const writable = {
    'identity': {'readerId'},
    'rfid': {
      'region',
      'hopTable',
      'session',
      'qValue',
      'target',
      'gen2RfMode',
      'rfidLevel',
      'uniByAnt',
      'uniByBank',
      'maxRssi',
      'invAntennas',
    },
    'io': {'exGet', 'tagInfoEx', 'tagGpo', 'indicatorGpo'},
    'network': {
      'localTcpPort',
      'ethConfig',
      'wifiDhcp',
      'wifiSsidPassw',
      'httpUrl',
      'timezone',
      'time',
    },
    'reporting': {'reportCfg', 'autoInvCfg'},
  };

  Object? at(List<Object> path) {
    Object? value = values;
    for (final part in path) {
      value = value is List ? value[part as int] : (value as Map)[part];
    }
    return value;
  }

  void set(List<Object> path, Object? value) {
    final parent = at(path.sublist(0, path.length - 1));
    if (parent is List) {
      parent[path.last as int] = value;
    } else {
      (parent as Map)[path.last] = value;
    }
  }

  bool changed(String group, String key) {
    final current = (values[group] as Map?)?[key];
    final original = (_original[group] as Map?)?[key];
    // The missing interval is not a change until the user supplies a value.
    if (group == 'reporting' && key == 'autoInvCfg' && current is Map) {
      final comparable = Map<String, Object?>.from(current);
      if (comparable['syncinterv'] == null) comparable.remove('syncinterv');
      return !_equal(comparable, original);
    }
    return !_equal(current, original);
  }

  Map<String, Object?> get patch {
    final result = <String, Object?>{};
    for (final group in writable.entries) {
      final current = values[group.key];
      if (current is! Map) continue;
      final changes = <String, Object?>{};
      for (final key in group.value) {
        if (!changed(group.key, key)) continue;
        Object? value = _copy(current[key]);
        if (group.key == 'network' &&
            (key == 'ethConfig' || key == 'wifiDhcp') &&
            value is List) {
          // Get: DHCP/IP/netmask/gateway. Set: IP/netmask/gateway (static IP).
          if (value.length == 4) value = value.sublist(1);
        }
        changes[key] = value;
      }
      if (changes.isNotEmpty) result[group.key] = changes;
    }
    if (!_equal(values['antennas'], _original['antennas'])) {
      result['antennas'] = _copy(values['antennas']);
    }
    return result;
  }

  static Object? _copy(Object? value) => switch (value) {
    Map map => {
      for (final entry in map.entries) entry.key.toString(): _copy(entry.value),
    },
    List list => list.map(_copy).toList(),
    _ => value,
  };

  static bool _equal(Object? a, Object? b) {
    if (a is Map && b is Map) {
      return a.length == b.length &&
          a.keys.every((key) => b.containsKey(key) && _equal(a[key], b[key]));
    }
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!_equal(a[i], b[i])) return false;
      }
      return true;
    }
    return a == b;
  }
}
