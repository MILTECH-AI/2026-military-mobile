part of 'store.dart';

const _backupTables = [
  'vehicles',
  'maintenance',
  'operations',
  'inspections',
  'questions',
  'predictions',
  'record_changes',
];
const _maxBackupBytes = 64 * 1024 * 1024;
const _maxDecodedBytes = 128 * 1024 * 1024;

class BackupSnapshot {
  BackupSnapshot._(this.tables, this.metadata, this.photos, this.created);
  final Map<String, List<Map<String, dynamic>>> tables;
  final List<Map<String, dynamic>> metadata;
  final Map<String, List<int>> photos;
  final String created;
  Map<String, int> get counts => {
    for (final e in tables.entries) e.key: e.value.length,
  };

  static Future<BackupSnapshot> read(File file) async {
    if (await file.length() > _maxBackupBytes) {
      throw const FormatException('백업 파일이 64MB를 초과합니다.');
    }
    final bytes = <int>[];
    await for (final chunk in gzip.decoder.bind(file.openRead())) {
      if (bytes.length + chunk.length > _maxDecodedBytes) {
        throw const FormatException('백업 내용이 허용 크기를 초과합니다.');
      }
      bytes.addAll(chunk);
    }
    return compute(
      (List<int> input) => _validate(jsonDecode(utf8.decode(input))),
      bytes,
    );
  }

  static BackupSnapshot _validate(dynamic decoded) {
    const error = FormatException('지원하지 않거나 손상된 백업 파일입니다.');
    if (decoded is! Map ||
        decoded['format'] != 'local-maintenance-backup' ||
        decoded['version'] != 1 ||
        decoded['schemaVersion'] != 4 ||
        decoded['tables'] is! Map ||
        decoded['photos'] is! Map ||
        decoded['metadata'] is! List ||
        decoded['created'] is! String) {
      throw error;
    }
    final tables = <String, List<Map<String, dynamic>>>{};
    final ids = <String, Set<String>>{};
    bool validId(dynamic id) =>
        id is String && RegExp(r'^[A-Za-z0-9가-힣_-]{1,120}$').hasMatch(id);
    bool text(dynamic value, [int limit = 10000]) =>
        value is String && value.length <= limit;
    bool nonnegative(dynamic value) =>
        value is int && value >= 0 && value <= 1000000000000;
    bool date(dynamic value) {
      if (!text(value, 40) ||
          !RegExp(r'^\d{4}-\d{2}-\d{2}(T.*)?$').hasMatch(value as String)) {
        return false;
      }
      final parsed = DateTime.tryParse(value);
      return parsed != null &&
          value.substring(0, 10) == parsed.toIso8601String().substring(0, 10);
    }

    if (!date(decoded['created']) ||
        (decoded['created'] as String).length < 10) {
      throw error;
    }
    for (final table in _backupTables) {
      final raw = decoded['tables'][table];
      if (raw is! List || raw.length > 100000) throw error;
      final list = <Map<String, dynamic>>[];
      final keys = <String>{};
      for (final value in raw) {
        if (value is! Map) throw error;
        final row = Map<String, dynamic>.from(value);
        if (!validId(row['id']) || !keys.add(row['id'] as String)) throw error;
        if (table != 'vehicles' && !validId(row['vehicleId'])) throw error;
        if (table == 'vehicles' || table == 'operations') {
          for (final key in ['distance', 'hours', 'fuel']) {
            if (!nonnegative(row[key])) throw error;
          }
        }
        switch (table) {
          case 'vehicles':
            if (!text(row['model'], 300) ||
                row['year'] is! int ||
                row['year'] < 1950 ||
                row['year'] > 2100 ||
                !nonnegative(row['risk']) ||
                row['risk'] > 100) {
              throw error;
            }
          case 'operations':
            if (table == 'operations' && !date(row['created'])) throw error;
          case 'maintenance':
            if ((row['conceptId'] != null && !validId(row['conceptId'])) ||
                (row['createdAt'] != null &&
                    (!date(row['createdAt']) ||
                        !row['createdAt'].contains('T'))) ||
                (row['updatedAt'] != null &&
                    (!date(row['updatedAt']) ||
                        !row['updatedAt'].contains('T')))) {
              throw error;
            }
            if (row['conceptConfirmedAt'] != null &&
                (!date(row['conceptConfirmedAt']) ||
                    !row['conceptConfirmedAt'].contains('T') ||
                    row['conceptId'] == null ||
                    !validId(row['conceptId']))) {
              throw error;
            }
            if ((row.containsKey('inspectionId') &&
                    !validId(row['inspectionId'])) ||
                (row.containsKey('replacementCompleted') &&
                    row['replacementCompleted'] is! bool) ||
                (row.containsKey('odometerKm') &&
                    !nonnegative(row['odometerKm'])) ||
                (row['replacementCompleted'] == true &&
                    !nonnegative(row['odometerKm']))) {
              throw error;
            }
            if (!date(row['date']) ||
                !text(row['part'], 300) ||
                (row['part'] as String).trim().isEmpty ||
                !text(row['description'], 5000) ||
                !nonnegative(row['cost']) ||
                ![
                  '냉각',
                  '제동',
                  '엔진/연료',
                  '전장',
                  '조향/현가',
                  '흡기/배기',
                  '동력전달',
                  '공조',
                  '차체',
                ].contains(row['system']) ||
                !['예방', '고장수리', '미분류'].contains(row['maintenanceType'])) {
              throw error;
            }
          case 'inspections':
            if ((row['conceptId'] != null && !validId(row['conceptId'])) ||
                (row['conceptConfirmedAt'] != null &&
                    (!date(row['conceptConfirmedAt']) ||
                        !(row['conceptConfirmedAt'] as String).contains('T') ||
                        row['conceptId'] == null)) ||
                (row['vision'] != null &&
                    (row['vision'] is! Map ||
                        jsonEncode(row['vision']).length > 20000))) {
              throw error;
            }
            if (!date(row['created']) ||
                !text(row['area'], 300) ||
                !text(row['mode'], 300) ||
                !text(row['note'], 10000) ||
                row.containsKey('imagePath') ||
                row['photoId'] != row['id']) {
              throw error;
            }
          case 'questions':
            if (!date(row['created']) ||
                !text(row['question'], 1000) ||
                (row.containsKey('standardPart') &&
                    !text(row['standardPart'], 300))) {
              throw error;
            }
          case 'predictions':
            final p = row['probability'];
            if (!date(row['created']) ||
                !date(row['observedAt']) ||
                !text(row['modelVersion'], 200) ||
                !text(row['trigger'], 300) ||
                !text(row['trainedOn'], 300) ||
                row['provisional'] is! bool ||
                (p != null && (p is! num || !p.isFinite || p < 0 || p > 1))) {
              throw error;
            }
            if (p != null && row['features'] is! Map) throw error;
          case 'record_changes':
            if (!date(row['created']) ||
                !validId(row['recordId']) ||
                !['maintenance', 'operations'].contains(row['table']) ||
                row['before'] is! Map ||
                (row['after'] != null && row['after'] is! Map)) {
              throw error;
            }
        }
        row.remove('_localOrder');
        list.add(row);
      }
      tables[table] = list;
      ids[table] = keys;
    }
    if (tables['vehicles']!.isEmpty) throw error;
    for (final row in tables['maintenance']!) {
      final owner = tables['vehicles']!.firstWhere(
        (v) => v['id'] == row['vehicleId'],
        orElse: () => {},
      );
      if (row['odometerKm'] != null &&
          (owner.isEmpty || row['odometerKm'] > owner['distance'])) {
        throw error;
      }
      if (row['inspectionId'] != null &&
          !tables['inspections']!.any(
            (i) =>
                i['id'] == row['inspectionId'] &&
                i['vehicleId'] == row['vehicleId'],
          )) {
        throw error;
      }
    }
    for (final table in _backupTables.skip(1)) {
      if (tables[table]!.any(
        (r) => !ids['vehicles']!.contains(r['vehicleId']),
      )) {
        throw error;
      }
    }
    // Preserve insertion order for same-time observations and verify all totals.
    final ops = <String, List<Map<String, dynamic>>>{};
    for (final row in tables['operations']!) {
      ops.putIfAbsent(row['vehicleId'] as String, () => []).add(row);
    }
    for (final rows in ops.values) {
      final order = {for (var i = 0; i < rows.length; i++) rows[i]['id']: i};
      rows.sort((a, b) {
        final c = (a['created'] as String).compareTo(b['created'] as String);
        return c != 0 ? c : order[a['id']]!.compareTo(order[b['id']]!);
      });
      for (var i = 1; i < rows.length; i++) {
        for (final key in ['distance', 'hours', 'fuel']) {
          if (rows[i][key] < rows[i - 1][key]) throw error;
        }
      }
      final vehicle = tables['vehicles']!.firstWhere(
        (v) => v['id'] == rows.last['vehicleId'],
      );
      for (final key in ['distance', 'hours', 'fuel']) {
        if (vehicle[key] != rows.last[key]) throw error;
      }
    }
    final photos = <String, List<int>>{};
    for (final e in (decoded['photos'] as Map).entries) {
      if (!validId(e.key) ||
          !ids['inspections']!.contains(e.key) ||
          e.value is! String) {
        throw error;
      }
      final photo = base64Decode(e.value as String);
      if (photo.isEmpty || photo.length > 10 * 1024 * 1024) throw error;
      photos[e.key as String] = photo;
    }
    if (photos.length != tables['inspections']!.length) throw error;
    final metadata = <Map<String, dynamic>>[];
    final metadataKeys = <String>{};
    for (final value in decoded['metadata'] as List) {
      if (value is! Map ||
          !['mock_dataset', 'maintenance_support'].contains(value['key']) ||
          !metadataKeys.add(value['key'] as String)) {
        throw error;
      }
      if (value['key'] == 'mock_dataset') {
        if (!['rexton-mock-v2', 'rexton-mock-v3'].contains(value['value'])) {
          throw error;
        }
      } else {
        if (value['value'] is! String) throw error;
        final library = SupportLibrary.decode(value['value']);
        if (library.rules.any((r) => !ids['vehicles']!.contains(r.vehicleId))) {
          throw error;
        }
        for (final r in tables['maintenance']!) {
          if (r['conceptId'] != null) {
            library.knowledge.requireConcept(r['conceptId']);
          }
        }
      }
      metadata.add(Map<String, dynamic>.from(value));
    }
    if (!metadataKeys.contains('mock_dataset')) throw error;
    return BackupSnapshot._(
      tables,
      metadata,
      photos,
      decoded['created'] as String,
    );
  }
}

extension BackupStorage on AppStore {
  Future<void> exportBackup(File destination) => _mutate(() async {
    final tables = <String, List<Map<String, dynamic>>>{};
    final photos = <String, String>{};
    final metadata = <Map<String, dynamic>>[];
    await db!.transaction(() async {
      for (final table in _backupTables) {
        final rows = await db!
            .customSelect('SELECT payload FROM $table ORDER BY rowid')
            .get();
        tables[table] = rows
            .map(
              (r) =>
                  jsonDecode(r.read<String>('payload')) as Map<String, dynamic>,
            )
            .toList();
      }
      for (final row
          in await db!
              .customSelect(
                "SELECT key,value FROM app_metadata WHERE key IN ('mock_dataset','maintenance_support')",
              )
              .get()) {
        metadata.add({
          'key': row.read<String>('key'),
          'value': row.read<String>('value'),
        });
      }
    });
    for (final row in tables['maintenance']!) {
      row['maintenanceType'] ??= '미분류';
    }
    for (final row in tables['inspections']!) {
      final image = File(row.remove('imagePath') as String);
      if (!await image.exists() ||
          await image.length() == 0 ||
          await image.length() > 10 * 1024 * 1024) {
        throw const FormatException('점검 사진이 없거나 너무 큽니다.');
      }
      photos[row['id'] as String] = base64Encode(await image.readAsBytes());
      row['photoId'] = row['id'];
    }
    final value = {
      'format': 'local-maintenance-backup',
      'version': 1,
      'schemaVersion': 4,
      'created': clock().toIso8601String(),
      'tables': tables,
      'metadata': metadata,
      'photos': photos,
    };
    final encoded = await compute(_encodeBackup, value);
    final temporary = File('${destination.path}.${newId('TMP')}.partial');
    try {
      await temporary.writeAsBytes(encoded, flush: true);
      await temporary.rename(destination.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  });

  Future<void> restoreBackup(
    BackupSnapshot snapshot,
    Directory imageDirectory,
  ) => _mutate(() async {
    // Revalidate the mutable payload before changing files or the live database.
    final value = {
      'format': 'local-maintenance-backup',
      'version': 1,
      'schemaVersion': 4,
      'created': snapshot.created,
      'tables': snapshot.tables,
      'metadata': snapshot.metadata,
      'photos': {
        for (final e in snapshot.photos.entries) e.key: base64Encode(e.value),
      },
    };
    final checked = BackupSnapshot._validate(value);
    final folder = Directory('${imageDirectory.path}/${newId('RESTORE')}');
    await folder.create(recursive: true);
    var committed = false;
    final previous = (
      vehicles: vehicles,
      records: records,
      operations: operations,
      inspections: inspections,
      questions: questions,
      predictions: predictions,
      history: predictionHistory,
    );
    final previousDirty = Map<String, String>.from(_dirtyVehicles);
    final previousSupport = supportLibrary;
    try {
      for (final row in checked.tables['inspections']!) {
        final id = row.remove('photoId') as String;
        final file = File('${folder.path}/$id.jpg');
        await file.writeAsBytes(checked.photos[id]!, flush: true);
        row['imagePath'] = file.path;
      }
      await db!.transaction(() async {
        for (final table in _backupTables.reversed) {
          await db!.customStatement('DELETE FROM $table');
        }
        await db!.customStatement('DELETE FROM app_metadata');
        for (final table in _backupTables) {
          for (final row in checked.tables[table]!) {
            await _put(
              table,
              row['id'] as String,
              row,
              vehicleId: table == 'vehicles'
                  ? null
                  : row['vehicleId'] as String,
            );
          }
        }
        for (final row in checked.metadata) {
          await db!.customStatement(
            'INSERT INTO app_metadata (key,value) VALUES (?,?)',
            [row['key'], row['value']],
          );
        }
        _dirtyVehicles.clear();
        for (final row in checked.tables['vehicles']!) {
          _dirtyVehicles[row['id'] as String] = '백업 복원';
        }
        // Recompute inside the same transaction: a failed model refresh must
        // roll back the restored DB as well as the screen's in-memory state.
        await _readState();
      });
      committed = true;
      _notifyChanged();
    } finally {
      if (!committed) {
        supportLibrary = previousSupport;
        vehicles = previous.vehicles;
        records = previous.records;
        operations = previous.operations;
        inspections = previous.inspections;
        questions = previous.questions;
        predictions = previous.predictions;
        predictionHistory = previous.history;
        _dirtyVehicles
          ..clear()
          ..addAll(previousDirty);
        if (await folder.exists()) {
          await folder.delete(recursive: true);
        }
      }
    }
  });
}

List<int> _encodeBackup(Map<String, dynamic> value) {
  final raw = utf8.encode(jsonEncode(value));
  if (raw.length > _maxDecodedBytes) {
    throw const FormatException('백업 내용이 128MB를 초과합니다.');
  }
  final encoded = gzip.encode(raw);
  if (encoded.length > _maxBackupBytes) {
    throw const FormatException('백업 파일이 64MB를 초과합니다.');
  }
  return encoded;
}
