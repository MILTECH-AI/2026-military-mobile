"""Deterministic synthetic Rexton data. Runs offline using Python's standard library.

References supply field names only. Original PDFs/rows are never opened here.
"""
import calendar
import hashlib
import json
import math
import random
from collections import Counter
from datetime import date, timedelta
from pathlib import Path

VERSION = 'rexton-mock-v3'
SEED = 20261009
PROVENANCE = dict(source='synthetic', isSynthetic=True, datasetVersion=VERSION)
OUT = Path('data/mock')
CATALOG = [
    ('오일 필터', '엔진/연료', 7000, '예방', '교환 주기 도달'),
    ('연료 필터', '엔진/연료', 42000, '예방', '필터 점검 주기 도달'),
    ('에어 클리너', '흡기/배기', 16000, '예방', '흡기 필터 오염'),
    ('EGR 밸브', '흡기/배기', 260000, '고장수리', '출력 저하'),
    ('DPF 압력 센서', '흡기/배기', 80000, '고장수리', '배기 경고 표시'),
    ('냉각수 호스', '냉각', 38000, '고장수리', '냉각수 감소'),
    ('워터 펌프', '냉각', 145000, '고장수리', '냉각 계통 소음'),
    ('서모스탯', '냉각', 62000, '고장수리', '수온 변화 편차'),
    ('전륜 브레이크 패드', '제동', 68000, '예방', '패드 점검 주기 도달'),
    ('브레이크 호스', '제동', 48000, '고장수리', '제동 압력 점검 이상'),
    ('브레이크 디스크', '제동', 115000, '고장수리', '제동 중 진동'),
    ('변속기 오일', '동력전달', 150000, '예방', '오일 교환 주기 도달'),
    ('변속기 센서', '동력전달', 58000, '고장수리', '변속 지연'),
    ('구동축 씰', '동력전달', 26000, '고장수리', '구동 계통 누유 흔적'),
    ('쇼크업소버', '조향/현가', 98000, '고장수리', '요철 통과 소음'),
    ('조향 조인트', '조향/현가', 54000, '고장수리', '조향 중 유격'),
    ('배터리', '전장', 210000, '고장수리', '시동 지연'),
    ('발전기', '전장', 310000, '고장수리', '충전 표시 이상'),
    ('후방 카메라', '전장', 140000, '고장수리', '후방 화면 끊김'),
    ('공조 필터', '공조', 22000, '예방', '실내 필터 교환 주기 도달'),
    ('공조 팬', '공조', 92000, '고장수리', '송풍량 감소'),
    ('도어 래치', '차체', 56000, '고장수리', '문 닫힘 불량'),
    ('적재함 고정 부품', '차체', 32000, '고장수리', '적재함 잠금 유격'),
];
TEMPLATES = {
    'train': [
        '가상 점검에서 {symptom} 확인. {part} 교환 후 작동 상태를 재점검함.',
        '목업 기록: {symptom} 발생으로 {part} 정비, 교환 후 상태 확인 완료.',
        '{symptom} 점검에 따라 {part} 교체 작업을 수행한 가상 정비 건.',
        '시뮬레이션 정비: {part} 상태 확인 및 교환. 접수 내용은 {symptom}.',
    ],
    'validation': [
        '시험용 접수 사유는 {symptom}. 조치는 {part} 교환과 기능 확인.',
        '{part}에 대한 가상 정비 접수 후 교환 완료. 관찰 사항: {symptom}.',
    ],
    'test': [
        '합성 사례에서 {symptom}을 기록하고 {part}를 바꾼 뒤 동작을 확인했다.',
        '가상 차량의 {part} 교체 건이며, 사전 점검 메모에는 {symptom}이 적혀 있다.',
    ],
}


def dump(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def jsonl(path, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('w', encoding='utf-8', newline='\n') as stream:
        for row in rows:
            stream.write(json.dumps(row, ensure_ascii=False, separators=(',', ':')) + '\n')


def month_at(index):
    offset = 2022 * 12 + 9 + index
    return offset // 12, offset % 12 + 1


def build():
    rng = random.Random(SEED)
    vehicles, operations, maintenance, prediction, classification = [], [], [], [], []
    for number in range(1, 501):
        vid = f'MOCK-RX-{number:04}'
        split = 'train' if number <= 350 else 'validation' if number <= 425 else 'test'
        # A release date no later than the first simulated observation.
        release = rng.randint(2007, 2022)
        distance = (2022 - release) * rng.randint(8000, 21000) + rng.randint(200, 9000)
        hours = round(distance / rng.uniform(30, 48))
        fuel = round(distance * rng.uniform(0.085, 0.135))
        scenario = ['regular_prevention', 'overdue_service', 'rising_usage',
                    'repeat_repairs', 'low_usage', 'heavy_usage'][(number-1) % 6]
        daily_usage = rng.randint(450, 1200)
        if scenario == 'low_usage':
            daily_usage = rng.randint(250, 500)
        if scenario == 'heavy_usage':
            daily_usage = rng.randint(1800, 2600)
        usage = float(daily_usage)
        wear = rng.uniform(0.05, 0.75)
        service_interval = 3 if scenario == 'regular_prevention' else 12
        service_phase = rng.randrange(service_interval)
        recurring_part = rng.choice([i for i, p in enumerate(CATALOG) if p[3] == '고장수리'])
        history, snapshots = [], []
        for index in range(49):
            year, month = month_at(index)
            month_start = date(year, month, 1)
            month_end = date(year, month, calendar.monthrange(year, month)[1])
            # Persistent workload; increasing use does not disappear next month.
            target = daily_usage * (1 + index * 0.025 if scenario == 'rising_usage' else 1)
            usage = 0.85 * usage + 0.15 * target + rng.uniform(-70, 70)
            driven = max(150, round(usage))
            added_hours = round(driven / rng.uniform(28, 48))
            distance += driven
            hours += added_hours
            # Hidden simulator state is NEVER a training feature. It persists and
            # creates observable fuel-efficiency degradation, not a real sensor.
            wear += 0.025 + driven / 28000 + (year-release) * 0.001
            events = []
            if index % service_interval == service_phase:
                events.append(rng.choice([i for i, p in enumerate(CATALOG) if p[3] == '예방']))
                wear = max(0.02, wear - 0.24)
            probability = 0.015 + 0.97 / (1 + math.exp(-max(-40, min(40, 15 * (wear - 0.82)))))
            if rng.random() < probability:
                events.append(recurring_part if scenario == 'repeat_repairs' else
                    rng.choice([i for i, p in enumerate(CATALOG) if p[3] == '고장수리']))
                # Incomplete fixes in recurring cases; other repairs restore state.
                wear = max(0.02, wear - (0.18 if scenario == 'repeat_repairs' else 0.55))
            wear = min(1.3, wear)
            used_fuel = round(driven * (0.085 + 0.085 * wear + rng.uniform(-0.004, 0.004)))
            fuel += used_fuel
            operation = {**PROVENANCE, 'id': f'MOCK-OP-{number:04}-{index:02}',
                'vehicleId': vid, 'created': month_end.isoformat() + 'T18:00:00',
                'distance': distance, 'hours': hours, 'fuel': fuel,
                'monthlyDistanceKm': driven, 'monthlyHours': added_hours,
                'monthlyFuelL': used_fuel}
            operations.append(operation)
            for event_number, part_index in enumerate(events):
                part, system, base_cost, kind, symptom = CATALOG[part_index]
                event_date = month_start + timedelta(days=rng.randrange(month_end.day))
                template_index = rng.randrange(len(TEMPLATES[split]))
                description = TEMPLATES[split][template_index].format(part=part, symptom=symptom)
                record = {**PROVENANCE, 'id': f'MOCK-MR-{number:04}-{index:02}-{event_number}',
                    'vehicleId': vid, 'date': event_date.isoformat(), 'part': part,
                    'system': system, 'description': description,
                    'cost': round(base_cost * rng.uniform(0.8, 1.3) / 1000) * 1000,
                    'maintenanceType': kind, 'split': split,
                    'templateId': f'{split}-{template_index}'}
                maintenance.append(record)
                history.append(record)
                classification.append({**PROVENANCE, 'id': record['id'], 'vehicleId': vid,
                    'split': split, 'templateId': record['templateId'],
                    'input': {'description': description, 'part': part},
                    'label': {'system': system, 'maintenanceType': kind}})
            recent = [r for r in history if (month_end - date.fromisoformat(r['date'])).days < 90]
            previous_date = max((date.fromisoformat(r['date']) for r in history), default=None)
            features = {'releaseYear': release, 'ageYears': year - release,
                'distanceKm': distance, 'operatingHours': hours, 'fuelL': fuel,
                'monthlyDistanceKm': driven, 'monthlyHours': added_hours, 'monthlyFuelL': used_fuel,
                'litersPer100Km': round(used_fuel / driven * 100, 3),
                'hasMaintenanceHistory': int(bool(history)),
                'daysSinceMaintenance': (month_end - previous_date).days if previous_date else -1,
                'maintenanceCount90Days': len(recent),
                'correctiveCount90Days': sum(r['maintenanceType'] == '고장수리' for r in recent),
                'maintenanceCost90DaysWon': sum(r['cost'] for r in recent)}
            snapshots.append((month_end, features))
            if index == 47:
                risk = min(95, max(5, round((year-release)*2 + distance/14000 +
                    features['correctiveCount90Days']*12)))
                vehicles.append({**PROVENANCE, 'id': vid, 'model': '렉스턴 스포츠 (가상)',
                    'year': release, 'distance': distance, 'hours': hours, 'fuel': fuel, 'risk': risk,
                    'riskOrigin': 'illustrative formula; not a trained model', 'split': split,
                    'scenario': scenario})
        for index, (cutoff, features) in enumerate(snapshots[:-1]):
            next_end = snapshots[index + 1][0]
            future = [r for r in history if cutoff < date.fromisoformat(r['date']) <= next_end
                and r['maintenanceType'] == '고장수리']
            prediction.append({**PROVENANCE, 'id': f'MOCK-PRED-{number:04}-{index:02}',
                'vehicleId': vid, 'split': split, 'observedAt': cutoff.isoformat(),
                'labelWindowEnd': next_end.isoformat(), 'scenario': scenario, 'features': features,
                'label': {'correctiveMaintenanceNextMonth': int(bool(future))}})
    app_ids = {f'MOCK-RX-{i:04}' for i in range(1, 101)}
    app_start, app_end = '2024-10-01', '2026-09-30'
    bootstrap = {**PROVENANCE,
        'vehicles': [v for v in vehicles if v['id'] in app_ids],
        'operations': [o for o in operations if o['vehicleId'] in app_ids and app_start <= o['created'][:10] <= app_end],
        'maintenance': [r for r in maintenance if r['vehicleId'] in app_ids and app_start <= r['date'] <= app_end]}
    return vehicles, operations, maintenance, prediction, classification, bootstrap


def main():
    vehicles, operations, maintenance, prediction, classification, bootstrap = build()
    dump(Path('assets/mock/bootstrap.json'), bootstrap)
    for name, rows in [('vehicles', vehicles), ('operations', operations),
                       ('maintenance', maintenance), ('training', prediction),
                       ('maintenance_classification', classification)]:
        jsonl(OUT / f'{name}.jsonl', rows)
    for task, rows in [('prediction', prediction), ('classification', classification)]:
        for split in ['train', 'validation', 'test']:
            jsonl(OUT / task / f'{split}.jsonl', [r for r in rows if r['split'] == split])
    files = [p for p in OUT.rglob('*.jsonl')]
    dump(OUT / 'manifest.json', {**PROVENANCE, 'seed': SEED,
        'referenceUse': 'PDF field names and generic part categories only; no original records',
        'counts': {'vehicles': len(vehicles), 'operations': len(operations),
            'maintenance': len(maintenance), 'prediction': len(prediction),
            'classification': len(classification)},
        'appCounts': {k: len(bootstrap[k]) for k in ['vehicles', 'operations', 'maintenance']},
        'vehicleSplits': {'train': 350, 'validation': 75, 'test': 75},
        'predictionSplits': dict(Counter(r['split'] for r in prediction)),
        'classificationSplits': dict(Counter(r['split'] for r in classification)),
        'positiveRate': round(sum(r['label']['correctiveMaintenanceNextMonth'] for r in prediction) / len(prediction), 4),
        'scenarioCounts': dict(Counter(v['scenario'] for v in vehicles)),
        'scenarioRules': 'Persistent workload and latent wear; fuel degradation proxy; scheduled prevention reduces wear; corrective repair restores wear; repeat repairs partly restore wear. Coefficients are fictional, not engineering estimates.',
        'featureNames': list(prediction[0]['features']),
        'labelMeaning': 'Synthetic corrective maintenance event in next calendar month; NOT confirmed failure',
        'missingValue': {'daysSinceMaintenance': -1},
        'splitRules': 'Disjoint vehicle IDs for both tasks; disjoint description template families for text task',
        'limitations': ['Handcrafted generator defines all labels; performance measures generator learning only',
            'No actual fault labels, sensors, images or manual text',
            'Fleet historical operations and maintenance are simulated, not recovered from source snapshots',
            'Part prices are fictional single-record costs in KRW; no labor/quantity/tax inference'],
        'sha256': {p.relative_to(OUT).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(files)}})
    print(json.dumps({'app': {k: len(bootstrap[k]) for k in ['vehicles', 'operations', 'maintenance']},
        'training': len(prediction), 'classification': len(classification)}, ensure_ascii=False))


if __name__ == '__main__':
    main()
