import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:path_provider/path_provider.dart';

import 'local_models.dart';
part 'backup.dart';
part 'maintenance_support.dart';
part 'knowledge_import.dart';
part 'service_policy.dart';

enum VehicleStatus { normal, caution, danger, unavailable }

class Vehicle {
  const Vehicle({
    required this.id,
    required this.model,
    required this.year,
    required this.distance,
    required this.hours,
    required this.fuel,
    required this.risk,
    this.cautionThreshold = 60,
    this.dangerThreshold = 80,
    this.predictionReady = false,
  });
  final String id, model;
  final int year, distance, hours, fuel, risk;
  final int cautionThreshold, dangerThreshold;
  final bool predictionReady;
  VehicleStatus get status => !predictionReady
      ? VehicleStatus.unavailable
      : risk >= dangerThreshold
      ? VehicleStatus.danger
      : risk >= cautionThreshold
      ? VehicleStatus.caution
      : VehicleStatus.normal;
  Map<String, dynamic> toJson() => {
    'id': id,
    'model': model,
    'year': year,
    'distance': distance,
    'hours': hours,
    'fuel': fuel,
    'risk': risk,
  };
  factory Vehicle.fromJson(Map<String, dynamic> j) => Vehicle(
    id: j['id'],
    model: j['model'],
    year: j['year'],
    distance: j['distance'],
    hours: j['hours'],
    fuel: j['fuel'],
    risk: j['risk'],
  );
}

class Maintenance {
  const Maintenance({
    required this.id,
    required this.vehicleId,
    required this.date,
    required this.part,
    required this.system,
    required this.description,
    required this.cost,
    this.maintenanceType = '미분류',
    this.inspectionId,
    this.odometerKm,
    this.replacementCompleted,
    this.conceptId,
    this.conceptConfirmedAt,
    this.createdAt,
    this.updatedAt,
  });
  final String id, vehicleId, date, part, system, description, maintenanceType;
  final int cost;
  final String? inspectionId;
  final int? odometerKm;
  // Null identifies older records whose work outcome was not captured.
  final bool? replacementCompleted;
  final String? conceptId, conceptConfirmedAt, createdAt, updatedAt;
  String? get confirmedConceptId =>
      conceptConfirmedAt == null ? null : conceptId;
  String? conceptAt(DateTime at) {
    final confirmed = DateTime.tryParse(conceptConfirmedAt ?? '');
    return confirmed == null || confirmed.isAfter(at) ? null : conceptId;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'vehicleId': vehicleId,
    'date': date,
    'part': part,
    'system': system,
    'description': description,
    'cost': cost,
    'maintenanceType': maintenanceType,
    if (inspectionId != null) 'inspectionId': inspectionId,
    if (odometerKm != null) 'odometerKm': odometerKm,
    if (replacementCompleted != null)
      'replacementCompleted': replacementCompleted,
    if (conceptId != null) 'conceptId': conceptId,
    if (conceptConfirmedAt != null) 'conceptConfirmedAt': conceptConfirmedAt,
    if (createdAt != null) 'createdAt': createdAt,
    if (updatedAt != null) 'updatedAt': updatedAt,
  };
  factory Maintenance.fromJson(Map<String, dynamic> j) => Maintenance(
    id: j['id'],
    vehicleId: j['vehicleId'],
    date: j['date'],
    part: j['part'],
    system: j['system'],
    description: j['description'],
    cost: j['cost'],
    maintenanceType: j['maintenanceType'] ?? '미분류',
    inspectionId: j['inspectionId'],
    odometerKm: j['odometerKm'],
    replacementCompleted: j['replacementCompleted'],
    conceptId: j['conceptId'],
    conceptConfirmedAt: j['conceptConfirmedAt'],
    createdAt: j['createdAt'],
    updatedAt: j['updatedAt'],
  );
}

class Inspection {
  const Inspection({
    required this.id,
    required this.vehicleId,
    required this.area,
    required this.mode,
    required this.created,
    required this.imagePath,
    required this.note,
    this.conceptId,
    this.conceptConfirmedAt,
    this.vision,
  });
  final String id, vehicleId, area, mode, created, imagePath, note;
  final String? conceptId, conceptConfirmedAt;
  final Map<String, dynamic>? vision;
  String? get confirmedConceptId =>
      conceptConfirmedAt == null ? null : conceptId;
  Map<String, dynamic> toJson() => {
    'id': id,
    'vehicleId': vehicleId,
    'area': area,
    'mode': mode,
    'created': created,
    'imagePath': imagePath,
    'note': note,
    if (conceptId != null) 'conceptId': conceptId,
    if (conceptConfirmedAt != null) 'conceptConfirmedAt': conceptConfirmedAt,
    if (vision != null) 'vision': vision,
  };
  factory Inspection.fromJson(Map<String, dynamic> j) => Inspection(
    id: j['id'],
    vehicleId: j['vehicleId'],
    area: j['area'],
    mode: j['mode'],
    created: j['created'],
    imagePath: j['imagePath'],
    note: j['note'],
    conceptId: j['conceptId'] as String?,
    conceptConfirmedAt: j['conceptConfirmedAt'] as String?,
    vision: j['vision'] == null
        ? null
        : Map<String, dynamic>.from(j['vision'] as Map),
  );
}

class LocalDatabase extends GeneratedDatabase {
  LocalDatabase(super.executor);
  @override
  int get schemaVersion => 4;
  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => const [];
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (_) async {
      await customStatement(
        'CREATE TABLE vehicles (id TEXT PRIMARY KEY, payload TEXT NOT NULL)',
      );
      await customStatement(
        'CREATE TABLE maintenance (id TEXT PRIMARY KEY, vehicle_id TEXT NOT NULL REFERENCES vehicles(id), payload TEXT NOT NULL)',
      );
      await customStatement(
        'CREATE TABLE operations (id TEXT PRIMARY KEY, vehicle_id TEXT NOT NULL REFERENCES vehicles(id), payload TEXT NOT NULL)',
      );
      await customStatement(
        'CREATE TABLE inspections (id TEXT PRIMARY KEY, vehicle_id TEXT NOT NULL REFERENCES vehicles(id), payload TEXT NOT NULL)',
      );
      await customStatement(
        'CREATE TABLE questions (id TEXT PRIMARY KEY, vehicle_id TEXT NOT NULL REFERENCES vehicles(id), payload TEXT NOT NULL)',
      );
      await customStatement(
        'CREATE TABLE app_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
      );
      await customStatement(
        'CREATE TABLE predictions (id TEXT PRIMARY KEY, vehicle_id TEXT NOT NULL REFERENCES vehicles(id), payload TEXT NOT NULL)',
      );
      await customStatement(
        'CREATE TABLE record_changes (id TEXT PRIMARY KEY, vehicle_id TEXT NOT NULL REFERENCES vehicles(id), payload TEXT NOT NULL)',
      );
    },
    onUpgrade: (_, from, to) async {
      if (from < 2) {
        await customStatement(
          'CREATE TABLE app_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
        );
      }
      if (from < 3) {
        await customStatement(
          'CREATE TABLE predictions (id TEXT PRIMARY KEY, vehicle_id TEXT NOT NULL REFERENCES vehicles(id), payload TEXT NOT NULL)',
        );
      }
      if (from < 4) {
        await customStatement(
          'CREATE TABLE record_changes (id TEXT PRIMARY KEY, vehicle_id TEXT NOT NULL REFERENCES vehicles(id), payload TEXT NOT NULL)',
        );
      }
    },
    beforeOpen: (_) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );
}

final storeProvider = ChangeNotifierProvider<AppStore>((ref) => AppStore());

class AppStore extends ChangeNotifier {
  AppStore({DateTime Function()? clock}) : clock = clock ?? DateTime.now;
  final DateTime Function() clock;
  LocalModels? models;
  SupportLibrary supportLibrary = const SupportLibrary();
  final supportDrafts = <String, SupportDraft>{};
  String? lastSupportVehicle;
  List<Map<String, dynamic>> predictionHistory = [];
  Map<String, Map<String, dynamic>> predictions = {};
  final _idRandom = math.Random.secure();
  final _dirtyVehicles = <String, String>{};
  Future<void>? _readQueue;
  Future<void>? _mutationQueue;
  void _notifyChanged() => notifyListeners();

  Future<T> _mutate<T>(Future<T> Function() action) {
    final result = _mutationQueue == null
        ? action()
        : _mutationQueue!.then((_) => action());
    _mutationQueue = result.then<void>((_) {}).catchError((Object _) {});
    return result;
  }

  LocalDatabase? db;
  bool ready = false;
  String? error;
  Object? initializationCause;
  List<Vehicle> vehicles = [];
  List<Maintenance> records = [];
  List<Inspection> inspections = [];
  List<Map<String, dynamic>> operations = [], questions = [];
  List<Map<String, dynamic>> temporalChanges = [];
  List<Vehicle> get registeredVehicles =>
      vehicles.where((v) => !v.id.startsWith('MOCK-')).toList();
  List<Vehicle> get activeVehicles =>
      registeredVehicles.isEmpty ? vehicles : registeredVehicles;

  Future<void> registerVehicle(Vehicle value) => _mutate(() async {
    if (!RegExp(r'^[A-Za-z0-9가-힣_-]{1,40}$').hasMatch(value.id) ||
        value.id.startsWith('MOCK-') ||
        vehicles.any((v) => v.id == value.id) ||
        value.model.trim().isEmpty ||
        value.model.length > 300 ||
        value.year < 1950 ||
        value.year > clock().year ||
        [
          value.distance,
          value.hours,
          value.fuel,
        ].any((n) => n < 0 || n > 1000000000000)) {
      throw ArgumentError('차량번호 중복·형식, 차종, 출고연도와 누적 계기를 확인해 주세요.');
    }
    await db!.transaction(() async {
      await _put('vehicles', value.id, {...value.toJson(), 'risk': 0});
      final id = newId('OP');
      await _put('operations', id, {
        'id': id,
        'vehicleId': value.id,
        'created': clock().toIso8601String(),
        'distance': value.distance,
        'hours': value.hours,
        'fuel': value.fuel,
      }, vehicleId: value.id);
    });
    await _read();
    notifyListeners();
  });

  String predictionUnavailableReason(String vehicleId) {
    final v = vehicle(vehicleId);
    if (!v.id.startsWith('MOCK-')) {
      return '등록 차량에는 합성 목업 예측을 적용하지 않습니다. 정비 주기를 확인해 주세요.';
    }
    if (!v.model.startsWith('렉스턴')) return '현재 목업 모델의 지원 차종이 아닙니다.';
    return assessPrediction(
          vehicle: v.toJson(),
          operations: operations,
          maintenance: records.map((r) => r.toJson()).toList(),
          asOf: clock(),
        ).reason ??
        '분석 대기 중입니다.';
  }

  Future<({int total, List<Map<String, dynamic>> rows})> recordChanges(
    String vehicleId, {
    int page = 0,
    int pageSize = 12,
  }) async {
    if (page < 0 || pageSize < 1 || pageSize > 100) {
      throw ArgumentError('잘못된 페이지입니다.');
    }
    return db!.transaction(() async {
      final count = await db!
          .customSelect(
            'SELECT COUNT(*) AS total FROM record_changes WHERE vehicle_id = ?',
            variables: [Variable<String>(vehicleId)],
          )
          .getSingle();
      final rows = await db!
          .customSelect(
            'SELECT payload FROM record_changes WHERE vehicle_id = ? ORDER BY rowid DESC LIMIT ? OFFSET ?',
            variables: [
              Variable<String>(vehicleId),
              Variable<int>(pageSize),
              Variable<int>(page * pageSize),
            ],
          )
          .get();
      return (
        total: count.read<int>('total'),
        rows: rows
            .map(
              (r) =>
                  jsonDecode(r.read<String>('payload')) as Map<String, dynamic>,
            )
            .toList(),
      );
    });
  }

  Future<void> initialize({LocalDatabase? database}) async {
    try {
      models ??= await LocalModels.load();
      if (database != null) {
        db = database;
      } else {
        final folder = await getApplicationDocumentsDirectory();
        db = LocalDatabase(
          NativeDatabase.createInBackground(
            File('${folder.path}/military.sqlite'),
          ),
        );
      }
      await _read();
      await _seed();
      await _read();
      ready = true;
      error = null;
      initializationCause = null;
    } catch (e) {
      initializationCause = e;
      error = '로컬 데이터를 열지 못했습니다. 다시 시도해 주세요.';
    }
    notifyListeners();
  }

  Future<List<Map<String, dynamic>>> _rows(String table) async =>
      (await db!
              .customSelect(
                'SELECT payload, rowid AS local_order FROM $table ORDER BY rowid DESC',
              )
              .get())
          .map(
            (r) => {
              ...jsonDecode(r.read<String>('payload')) as Map<String, dynamic>,
              if (table == 'operations')
                '_localOrder': r.read<int>('local_order'),
            },
          )
          .toList();
  Future<void> _read() {
    final next = _readQueue == null
        ? _readState()
        : _readQueue!.then((_) => _readState());
    _readQueue = next.catchError((Object _) {});
    return next;
  }

  Future<void> _readState() async {
    final dirty = Map<String, String>.from(_dirtyVehicles);
    _dirtyVehicles.clear();
    vehicles = (await _rows('vehicles')).map(Vehicle.fromJson).toList()
      ..sort((a, b) => b.risk.compareTo(a.risk));
    records = (await _rows('maintenance')).map(Maintenance.fromJson).toList()
      ..sort((a, b) => b.date.compareTo(a.date));
    operations = await _rows('operations');
    questions = await _rows('questions');
    inspections = (await _rows('inspections'))
        .map(Inspection.fromJson)
        .toList();
    final supportRow = await db!
        .customSelect(
          "SELECT value FROM app_metadata WHERE key = 'maintenance_support'",
        )
        .getSingleOrNull();
    supportLibrary = supportRow == null
        ? const SupportLibrary()
        : SupportLibrary.decode(supportRow.read<String>('value'));
    temporalChanges = supportLibrary.knowledge.templates.isEmpty
        ? []
        : await _rows('record_changes');
    await _refreshPredictions(dirty);
  }

  Future<void> _refreshPredictions(Map<String, String> dirty) async {
    final latestRows = await db!
        .customSelect(
          'SELECT payload FROM predictions WHERE rowid IN (SELECT MAX(rowid) FROM predictions GROUP BY vehicle_id)',
        )
        .get();
    final latest = {
      for (final row in latestRows)
        (jsonDecode(row.read<String>('payload'))
                    as Map<String, dynamic>)['vehicleId']
                as String:
            jsonDecode(row.read<String>('payload')) as Map<String, dynamic>,
    };
    predictions = {
      for (final entry in latest.entries)
        if (entry.value['probability'] is num) entry.key: entry.value,
    };
    final time = clock();
    final asOf = DateTime(time.year, time.month, time.day);
    final rawMaintenance = records.map((r) => r.toJson()).toList();
    await db!.transaction(() async {
      for (final v in vehicles) {
        if (!v.id.startsWith('MOCK-') || !v.model.startsWith('렉스턴')) {
          predictions.remove(v.id);
          continue;
        }
        final previous = latest[v.id];
        final currentVersion =
            previous?['qualityPolicy'] == 1 &&
            previous?['modelVersion'] == models!.version &&
            previous?['observedAt'] == asOf.toIso8601String().substring(0, 10);
        if (currentVersion && !dirty.containsKey(v.id)) {
          continue;
        }
        final assessment = assessPrediction(
          vehicle: v.toJson(),
          operations: operations,
          maintenance: rawMaintenance,
          asOf: asOf,
        );
        final features = assessment.features;
        if (features == null) {
          predictions.remove(v.id);
          if (currentVersion &&
              previous?['probability'] == null &&
              previous?['unavailableReason'] == assessment.reason) {
            continue;
          }
        }
        if (previous?['qualityPolicy'] == 1 &&
            previous?['unavailableReason'] == assessment.reason &&
            previous?['modelVersion'] == models!.version &&
            previous?['observedAt'] ==
                asOf.toIso8601String().substring(0, 10) &&
            jsonEncode(previous?['features']) == jsonEncode(features)) {
          continue;
        }
        final probability = features == null ? null : models!.predict(features);
        final value = <String, dynamic>{
          'id': newId('PRED'),
          'vehicleId': v.id,
          'created': time.toIso8601String(),
          'observedAt': asOf.toIso8601String().substring(0, 10),
          'modelVersion': models!.version,
          'trainedOn': models!.prediction['trainedOn'],
          'probability': probability,
          'features': features,
          'trigger': dirty[v.id] ?? '앱 실행',
          'qualityPolicy': 1,
          if (features == null) 'unavailableReason': assessment.reason,
          'provisional': asOf.day != DateTime(asOf.year, asOf.month + 1, 0).day,
        };
        await _put(
          'predictions',
          value['id'] as String,
          value,
          vehicleId: v.id,
        );
        if (probability != null) {
          predictions[v.id] = value;
        }
      }
    });
    vehicles =
        vehicles
            .map(
              (v) => Vehicle(
                id: v.id,
                model: v.model,
                year: v.year,
                distance: v.distance,
                hours: v.hours,
                fuel: v.fuel,
                risk: predictions[v.id] == null
                    ? v.risk
                    : ((predictions[v.id]!['probability'] as num) * 100)
                          .round(),
                cautionThreshold: predictions[v.id] == null
                    ? 60
                    : (models!.threshold * 100).round(),
                dangerThreshold: predictions[v.id] == null ? 80 : 50,
                predictionReady: predictions.containsKey(v.id),
              ),
            )
            .toList()
          ..sort(
            (a, b) => (b.predictionReady ? b.risk : -1).compareTo(
              a.predictionReady ? a.risk : -1,
            ),
          );
    predictionHistory =
        (await db!
                .customSelect(
                  'SELECT payload FROM predictions ORDER BY rowid DESC LIMIT 1000',
                )
                .get())
            .map(
              (r) =>
                  jsonDecode(r.read<String>('payload')) as Map<String, dynamic>,
            )
            .where((r) => r['probability'] is num)
            .toList();
  }

  MaintenanceSuggestion suggestMaintenance(String part, String description) =>
      models!.classify(part, description);

  Future<void> _put(
    String table,
    String id,
    Map<String, dynamic> data, {
    String? vehicleId,
  }) async {
    data = {'source': 'local_input', 'isSynthetic': null, ...data};
    if (vehicleId == null) {
      await db!.customStatement(
        'INSERT OR REPLACE INTO $table (id,payload) VALUES (?,?)',
        [id, jsonEncode(data)],
      );
    } else {
      await db!.customStatement(
        'INSERT INTO $table (id,vehicle_id,payload) VALUES (?,?,?)',
        [id, vehicleId, jsonEncode(data)],
      );
    }
  }

  Vehicle vehicle(String id) => vehicles.firstWhere((v) => v.id == id);
  List<Maintenance> history(String id) =>
      records.where((r) => r.vehicleId == id).toList();
  String newId(String prefix) =>
      '$prefix-${List.generate(16, (_) => _idRandom.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
  void _validateMaintenance(Maintenance record) {
    if (!vehicles.any((v) => v.id == record.vehicleId) ||
        record.cost < 0 ||
        record.cost > 1000000000000 ||
        record.part.trim().isEmpty ||
        record.description.trim().isEmpty) {
      throw ArgumentError('정비 입력값을 확인해 주세요.');
    }
    if (!['예방', '고장수리', '미분류'].contains(record.maintenanceType)) {
      throw ArgumentError('정비 구분을 확인해 주세요.');
    }
    if (record.inspectionId != null &&
        !inspections.any(
          (i) => i.id == record.inspectionId && i.vehicleId == record.vehicleId,
        )) {
      throw ArgumentError('같은 차량의 점검 기록을 연결해 주세요.');
    }
    if ((record.odometerKm != null &&
            (record.odometerKm! < 0 ||
                record.odometerKm! > vehicle(record.vehicleId).distance)) ||
        (record.replacementCompleted == true && record.odometerKm == null)) {
      throw ArgumentError('교환 당시 계기를 확인해 주세요. 현재 누적 계기 이하여야 합니다.');
    }
    if (record.replacementCompleted == true &&
        records.any(
          (r) =>
              r.id != record.id &&
              r.vehicleId == record.vehicleId &&
              r.replacementCompleted == true &&
              matchesPart(r.part, record.part) &&
              r.odometerKm != null &&
              ((r.date.compareTo(record.date) < 0 &&
                      r.odometerKm! > record.odometerKm!) ||
                  (r.date.compareTo(record.date) > 0 &&
                      r.odometerKm! < record.odometerKm!)),
        )) {
      throw ArgumentError('앞뒤 교환 기록의 날짜와 누적 계기가 맞지 않습니다.');
    }
    final date = DateTime.tryParse(record.date);
    final today = clock();
    if (date == null ||
        record.date != date.toIso8601String().substring(0, 10) ||
        date.year < vehicle(record.vehicleId).year ||
        date.isAfter(DateTime(today.year, today.month, today.day)) ||
        record.part.length > 300 ||
        record.description.length > 5000 ||
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
        ].contains(record.system)) {
      throw ArgumentError('정비 날짜와 입력값을 확인해 주세요.');
    }
    if (records.any(
      (r) =>
          r.id != record.id &&
          r.vehicleId == record.vehicleId &&
          r.date == record.date &&
          r.part.trim() == record.part.trim() &&
          r.description.trim() == record.description.trim() &&
          r.cost == record.cost &&
          r.system == record.system &&
          r.maintenanceType == record.maintenanceType &&
          r.inspectionId == record.inspectionId &&
          r.odometerKm == record.odometerKm &&
          r.replacementCompleted == record.replacementCompleted,
    )) {
      throw ArgumentError('동일한 정비 기록이 이미 있습니다.');
    }
  }

  Map<String, dynamic> _conceptConfirmation(
    Maintenance record,
    String? confirmedConceptId,
    bool clearConcept,
    Map<String, dynamic>? before,
  ) {
    if (confirmedConceptId != null) {
      supportLibrary.knowledge.requireConcept(confirmedConceptId);
      return {
        'conceptId': confirmedConceptId,
        'conceptConfirmedAt':
            before?['part'] == record.part &&
                before?['conceptId'] == confirmedConceptId &&
                before?['conceptConfirmedAt'] != null
            ? before!['conceptConfirmedAt']
            : clock().toIso8601String(),
      };
    }
    if (!clearConcept &&
        before?['part'] == record.part &&
        before?['conceptConfirmedAt'] != null) {
      return {
        'conceptId': before!['conceptId'],
        'conceptConfirmedAt': before['conceptConfirmedAt'],
      };
    }
    return {};
  }

  Future<void> addMaintenance(
    Maintenance record, {
    String? confirmedConceptId,
  }) => _mutate(() async {
    _validateMaintenance(record);
    await _put('maintenance', record.id, {
      ...(record.toJson()
        ..remove('conceptId')
        ..remove('conceptConfirmedAt')),
      ..._conceptConfirmation(record, confirmedConceptId, false, null),
      'createdAt': clock().toIso8601String(),
      'updatedAt': clock().toIso8601String(),
    }, vehicleId: record.vehicleId);
    _dirtyVehicles[record.vehicleId] = '정비 입력';
    await _read();
    notifyListeners();
  });

  Future<void> updateOperation(
    String id,
    int year,
    int distance,
    int hours,
    int fuel,
  ) => _mutate(() async {
    final old = vehicle(id);
    if (year < 1950 ||
        year > clock().year ||
        distance < old.distance ||
        hours < old.hours ||
        fuel < old.fuel) {
      throw ArgumentError('출고연도와 누적 운용값을 확인해 주세요.');
    }
    final updated = Vehicle(
      // Large accidental entries must remain portable to a validated backup.
      id: id,
      model: old.model,
      year: year,
      distance: distance,
      hours: hours,
      fuel: fuel,
      risk: old.risk,
    );
    if ([distance, hours, fuel].any((v) => v > 1000000000000)) {
      throw ArgumentError('누적 운용값이 허용 범위를 초과합니다.');
    }
    await db!.transaction(() async {
      await _put('vehicles', id, updated.toJson());
      final key = newId('OP');
      await _put('operations', key, {
        'id': key,
        'vehicleId': id,
        'created': clock().toIso8601String(),
        'distance': distance,
        'hours': hours,
        'fuel': fuel,
      }, vehicleId: id);
    });
    _dirtyVehicles[id] = '운용 입력';
    await _read();
    notifyListeners();
  });

  Future<void> saveInspection(Inspection value, {String? confirmedConceptId}) =>
      _mutate(() async {
        final before = inspections.where((i) => i.id == value.id).firstOrNull;
        final data = value.toJson()
          ..remove('conceptId')
          ..remove('conceptConfirmedAt');
        if (confirmedConceptId != null) {
          if (before == null ||
              before.imagePath != value.imagePath ||
              before.vehicleId != value.vehicleId) {
            throw StateError('점검 원본이 변경됐습니다. 다시 확인해 주세요.');
          }
          final concept = supportLibrary.knowledge.concepts
              .where((c) => c['id'] == confirmedConceptId)
              .firstOrNull;
          if (concept == null) throw ArgumentError('등록된 부품 개념을 선택해 주세요.');
          data['area'] = concept['name'];
          data['conceptId'] = confirmedConceptId;
          data['conceptConfirmedAt'] = clock().toIso8601String();
        } else if (before != null &&
            before.area == value.area &&
            before.imagePath == value.imagePath) {
          if (before.conceptId != null) data['conceptId'] = before.conceptId;
          if (before.conceptConfirmedAt != null) {
            data['conceptConfirmedAt'] = before.conceptConfirmedAt;
          }
        }
        if (before != null) {
          if (before.vehicleId != value.vehicleId) {
            throw ArgumentError('점검 기록의 차량을 변경할 수 없습니다.');
          }
          if (before.imagePath != value.imagePath) {
            data.remove('vision');
          } else if (value.vision == null && before.vision != null) {
            data['vision'] = before.vision;
          }
          await db!.customStatement(
            'UPDATE inspections SET payload = ? WHERE id = ?',
            [jsonEncode(data), value.id],
          );
        } else {
          await _put('inspections', value.id, data, vehicleId: value.vehicleId);
        }
        await _read();
        notifyListeners();
      });

  Future<void> saveQuestion(String id, String question, {String? partName}) =>
      _mutate(() async {
        if (question.trim().isEmpty || question.length > 1000) {
          throw ArgumentError('질문은 1~1,000자로 입력해 주세요.');
        }
        if (partName != null && partName.length > 300) {
          throw ArgumentError('부품명은 300자 이내로 입력해 주세요.');
        }
        final key = newId('QA');
        await _put('questions', key, {
          'id': key,
          'vehicleId': id,
          'question': question,
          if (partName != null && partName.isNotEmpty)
            'standardPart': standardPart(partName),
          'created': clock().toIso8601String(),
        }, vehicleId: id);
        await _read();
        notifyListeners();
      });

  Future<Map<String, dynamic>> _storedRecord(String table, String id) async {
    final row = await db!
        .customSelect(
          'SELECT payload FROM $table WHERE id = ?',
          variables: [Variable<String>(id)],
        )
        .getSingleOrNull();
    if (row == null) throw ArgumentError('기록을 찾을 수 없습니다.');
    return jsonDecode(row.read<String>('payload')) as Map<String, dynamic>;
  }

  Future<void> _changeLog(
    String table,
    Map<String, dynamic> before,
    Map<String, dynamic>? after,
  ) async {
    final id = newId('CHANGE');
    await _put('record_changes', id, {
      'id': id,
      'vehicleId': before['vehicleId'],
      'recordId': before['id'],
      'table': table,
      'before': before,
      'after': after,
      'created': clock().toIso8601String(),
    }, vehicleId: before['vehicleId'] as String);
  }

  Future<void> editMaintenance(
    Maintenance record, {
    String? confirmedConceptId,
    bool clearConcept = false,
  }) => _mutate(() async {
    _validateMaintenance(record);
    final before = await _storedRecord('maintenance', record.id);
    final after = {
      ...(record.toJson()
        ..remove('conceptId')
        ..remove('conceptConfirmedAt')),
      'createdAt': before['createdAt'] ?? clock().toIso8601String(),
      'updatedAt': clock().toIso8601String(),
      ..._conceptConfirmation(record, confirmedConceptId, clearConcept, before),
      'source': 'local_input',
      'isSynthetic': null,
    };
    await db!.transaction(() async {
      await db!.customStatement(
        'UPDATE maintenance SET vehicle_id = ?, payload = ? WHERE id = ?',
        [record.vehicleId, jsonEncode(after), record.id],
      );
      await _changeLog('maintenance', before, after);
    });
    _dirtyVehicles[before['vehicleId'] as String] = '정비 수정';
    _dirtyVehicles[record.vehicleId] = '정비 수정';
    await _read();
    notifyListeners();
  });

  Future<void> deleteMaintenance(String id) => _mutate(() async {
    final before = await _storedRecord('maintenance', id);
    await db!.transaction(() async {
      await _changeLog('maintenance', before, null);
      await db!.customStatement('DELETE FROM maintenance WHERE id = ?', [id]);
    });
    _dirtyVehicles[before['vehicleId'] as String] = '정비 삭제';
    await _read();
    notifyListeners();
  });

  Future<void> _syncOperationTotals(String vehicleId) async {
    final rows =
        (await _rows(
          'operations',
        )).where((r) => r['vehicleId'] == vehicleId).toList()..sort((a, b) {
          final c = (a['created'] as String).compareTo(b['created'] as String);
          return c != 0
              ? c
              : (a['_localOrder'] as int).compareTo(b['_localOrder'] as int);
        });
    final value = await _storedRecord('vehicles', vehicleId);
    for (final key in ['distance', 'hours', 'fuel']) {
      value[key] = rows.isEmpty ? 0 : rows.last[key];
    }
    await _put('vehicles', vehicleId, value);
  }

  Future<void> editOperation(String id, int distance, int hours, int fuel) =>
      _mutate(() async {
        final before = await _storedRecord('operations', id);
        final vid = before['vehicleId'] as String;
        final sorted =
            (await _rows('operations'))
                .where((r) => r['vehicleId'] == vid)
                .toList()
              ..sort((a, b) {
                final c = (a['created'] as String).compareTo(
                  b['created'] as String,
                );
                return c != 0
                    ? c
                    : (a['_localOrder'] as int).compareTo(
                        b['_localOrder'] as int,
                      );
              });
        final index = sorted.indexWhere((r) => r['id'] == id);
        final values = {'distance': distance, 'hours': hours, 'fuel': fuel};
        for (final e in values.entries) {
          if (e.value < 0 ||
              e.value > 1000000000000 ||
              (index > 0 && e.value < (sorted[index - 1][e.key] as int)) ||
              (index < sorted.length - 1 &&
                  e.value > (sorted[index + 1][e.key] as int))) {
            throw ArgumentError('앞뒤 기록의 누적값 범위 안에서 수정해 주세요.');
          }
        }
        final after =
            {...before, ...values, 'source': 'local_input', 'isSynthetic': null}
              ..remove('monthlyDistanceKm')
              ..remove('monthlyHours')
              ..remove('monthlyFuelL');
        await db!.transaction(() async {
          await db!.customStatement(
            'UPDATE operations SET payload = ? WHERE id = ?',
            [jsonEncode(after), id],
          );
          await _changeLog('operations', before, after);
          await _syncOperationTotals(vid);
        });
        _dirtyVehicles[vid] = '운용 수정';
        await _read();
        notifyListeners();
      });

  Future<void> deleteOperation(String id) => _mutate(() async {
    final before = await _storedRecord('operations', id);
    final vid = before['vehicleId'] as String;
    await db!.transaction(() async {
      await _changeLog('operations', before, null);
      await db!.customStatement('DELETE FROM operations WHERE id = ?', [id]);
      await _syncOperationTotals(vid);
    });
    _dirtyVehicles[vid] = '운용 삭제';
    await _read();
    notifyListeners();
  });

  Future<void> _seed() async {
    const version = 'rexton-mock-v3';
    final previous = await db!
        .customSelect(
          'SELECT value FROM app_metadata WHERE key = ?',
          variables: [const Variable<String>('mock_dataset')],
        )
        .getSingleOrNull();
    if (previous?.read<String>('value') == version) return;
    final payload = jsonDecode(
      await rootBundle.loadString('assets/mock/bootstrap.json'),
    ) as Map<String, dynamic>;
    if (payload['isSynthetic'] != true ||
        payload['datasetVersion'] != version) {
      throw const FormatException('Invalid mock dataset');
    }
    await db!.transaction(() async {
      final protectedVehicles = <String>{};
      if (previous?.read<String>('value') == 'rexton-mock-v2') {
        // Replace only untouched old synthetic histories. A vehicle with local
        // edits keeps its complete history; never mix two simulated timelines.
        for (final table in ['maintenance', 'operations', 'record_changes']) {
          final existing = await db!
              .customSelect('SELECT vehicle_id,payload FROM $table')
              .get();
          for (final row in existing) {
            final value = jsonDecode(row.read<String>('payload')) as Map;
            if (value['isSynthetic'] != true) {
              protectedVehicles.add(row.read<String>('vehicle_id'));
            }
          }
        }
        for (final table in ['maintenance', 'operations', 'vehicles']) {
          final existing = await db!
              .customSelect('SELECT id,payload FROM $table')
              .get();
          for (final row in existing) {
            final value = jsonDecode(row.read<String>('payload')) as Map;
            final vehicleId = table == 'vehicles'
                ? value['id'] as String
                : value['vehicleId'] as String;
            if (protectedVehicles.contains(vehicleId)) continue;
            if (value['isSynthetic'] == true &&
                value['datasetVersion'] == 'rexton-mock-v2') {
              if (table != 'vehicles') {
                await db!.customStatement('DELETE FROM $table WHERE id = ?', [
                  row.read<String>('id'),
                ]);
              } else {
                final replacement = (payload['vehicles'] as List).where(
                  (v) => (v as Map)['id'] == vehicleId,
                );
                if (replacement.isNotEmpty) {
                  await _put(
                    table,
                    vehicleId,
                    Map<String, dynamic>.from(replacement.first as Map),
                  );
                  _dirtyVehicles[vehicleId] = '목업 갱신';
                }
              }
            }
          }
        }
      }
      for (final table in ['vehicles', 'maintenance', 'operations']) {
        for (final raw in payload[table] as List<dynamic>) {
          final row = Map<String, dynamic>.from(raw as Map);
          final vehicleId = table == 'vehicles' ? row['id'] : row['vehicleId'];
          if (protectedVehicles.contains(vehicleId)) continue;
          if (row['isSynthetic'] != true) {
            throw const FormatException('Missing synthetic provenance');
          }
          final exists = await db!
              .customSelect(
                'SELECT id FROM $table WHERE id = ?',
                variables: [Variable<String>(row['id'] as String)],
              )
              .getSingleOrNull();
          if (exists != null) continue;
          await _put(
            table,
            row['id'] as String,
            row,
            vehicleId: table == 'vehicles' ? null : row['vehicleId'] as String,
          );
        }
      }
      await db!.customStatement(
        'INSERT OR REPLACE INTO app_metadata (key,value) VALUES (?,?)',
        ['mock_dataset', version],
      );
    });
  }

  @override
  void dispose() {
    db?.close();
    super.dispose();
  }
}
