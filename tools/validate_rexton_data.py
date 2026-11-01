"""Offline integrity/causality checks. No third-party packages needed."""
import hashlib
import json
from collections import Counter, defaultdict
from datetime import date
from pathlib import Path

ROOT = Path('data/mock')


def read(name):
    return [json.loads(line) for line in (ROOT / f'{name}.jsonl').read_text(encoding='utf-8').splitlines()]


def main():
    manifest = json.loads((ROOT / 'manifest.json').read_text(encoding='utf-8'))
    for name, digest in manifest['sha256'].items():
        assert hashlib.sha256((ROOT / name).read_bytes()).hexdigest() == digest, name
    vehicles = {v['id']: v for v in read('vehicles')}
    assert len({v['scenario'] for v in vehicles.values()}) == 6
    ops, repairs = defaultdict(list), defaultdict(list)
    for name in ['operations', 'maintenance', 'training', 'maintenance_classification']:
        rows = read(name)
        assert len({r['id'] for r in rows}) == len(rows), name
        for row in rows:
            assert row['isSynthetic'] is True and row['source'] == 'synthetic'
            assert row['vehicleId'] in vehicles and row['vehicleId'].startswith('MOCK-RX-')
            if 'split' in row:
                assert row['split'] == vehicles[row['vehicleId']]['split']
    for row in read('operations'):
        ops[row['vehicleId']].append(row)
    for vid, rows in ops.items():
        rows.sort(key=lambda r: r['created'])
        for previous, current in zip(rows, rows[1:]):
            for total, monthly in [('distance', 'monthlyDistanceKm'), ('hours', 'monthlyHours'), ('fuel', 'monthlyFuelL')]:
                assert current[total] - previous[total] == current[monthly]
        final = rows[-2]
        assert all(vehicles[vid][k] == final[k] for k in ['distance', 'hours', 'fuel'])
    for row in read('maintenance'):
        assert int(row['date'][:4]) >= vehicles[row['vehicleId']]['year']
        assert row['cost'] > 0
        repairs[row['vehicleId']].append(row)
    op_index = {(r['vehicleId'], r['created'][:10]): r for r in read('operations')}
    for row in read('training'):
        vid, cutoff, end = row['vehicleId'], date.fromisoformat(row['observedAt']), date.fromisoformat(row['labelWindowEnd'])
        history = [r for r in repairs[vid] if date.fromisoformat(r['date']) <= cutoff]
        recent = [r for r in history if (cutoff - date.fromisoformat(r['date'])).days < 90]
        future = [r for r in repairs[vid] if cutoff < date.fromisoformat(r['date']) <= end and r['maintenanceType'] == '고장수리']
        f = row['features']
        assert f['maintenanceCount90Days'] == len(recent)
        assert f['maintenanceCost90DaysWon'] == sum(r['cost'] for r in recent)
        assert f['correctiveCount90Days'] == sum(r['maintenanceType'] == '고장수리' for r in recent)
        latest = max((date.fromisoformat(r['date']) for r in history), default=None)
        assert f['daysSinceMaintenance'] == ((cutoff - latest).days if latest else -1)
        assert row['label']['correctiveMaintenanceNextMonth'] == int(bool(future))
        operation = op_index[(vid, cutoff.isoformat())]
        assert f['distanceKm'] == operation['distance'] and f['fuelL'] == operation['fuel']
        assert f['operatingHours'] == operation['hours']
        assert f['releaseYear'] == vehicles[vid]['year']
        assert f['ageYears'] == cutoff.year - vehicles[vid]['year']
        assert f['hasMaintenanceHistory'] == int(bool(history))
        for feature, field in [('monthlyDistanceKm', 'monthlyDistanceKm'),
                               ('monthlyHours', 'monthlyHours'), ('monthlyFuelL', 'monthlyFuelL')]:
            assert f[feature] == operation[field]
        assert f['litersPer100Km'] == round(operation['monthlyFuelL'] / operation['monthlyDistanceKm'] * 100, 3)
        assert row['scenario'] == vehicles[vid]['scenario']
        assert not {'wear', 'scenario', 'probability', 'risk'} & f.keys()
        assert 'risk' not in f and 'coolantTemperatureC' not in f
    texts, templates = defaultdict(set), defaultdict(set)
    for row in read('maintenance_classification'):
        texts[row['split']].add(row['input']['description'])
        templates[row['split']].add(row['templateId'])
    for a, b in [('train', 'validation'), ('train', 'test'), ('validation', 'test')]:
        assert not texts[a] & texts[b] and not templates[a] & templates[b]
    for task, full_name in [('prediction', 'training'), ('classification', 'maintenance_classification')]:
        counts = Counter(r['split'] for r in read(full_name))
        for split, count in counts.items():
            rows = read(f'{task}/{split}')
            assert len(rows) == count and all(r['split'] == split for r in rows)
            if task == 'prediction':
                assert {r['label']['correctiveMaintenanceNextMonth'] for r in rows} == {0, 1}
            else:
                assert len({r['label']['system'] for r in rows}) == 9
                assert {r['label']['maintenanceType'] for r in rows} == {'예방', '고장수리'}
    bootstrap = json.loads(Path('assets/mock/bootstrap.json').read_text(encoding='utf-8'))
    assert {k: len(bootstrap[k]) for k in ['vehicles', 'operations', 'maintenance']} == manifest['appCounts']
    ids = {v['id'] for v in bootstrap['vehicles']}
    assert len(ids) == 100
    for table in ['operations', 'maintenance']:
        assert all(r['vehicleId'] in ids for r in bootstrap[table])
    report = {'status': 'passed', 'checks': ['hashes', 'synthetic provenance', 'references',
        'cumulative totals', 'chronology', 'snapshot-only features', 'future labels',
        'disjoint vehicles and text templates', 'split files', 'APK seed counts'],
        'counts': manifest['counts'], 'appCounts': manifest['appCounts'],
        'scenarioCounts': manifest['scenarioCounts'],
        'predictionLabelCountsBySplit': {
            split: dict(Counter(str(r['label']['correctiveMaintenanceNextMonth'])
                for r in read(f'prediction/{split}'))) for split in ['train', 'validation', 'test']},
        'classificationSystemCountsBySplit': {
            split: dict(Counter(r['label']['system'] for r in read(f'classification/{split}')))
            for split in ['train', 'validation', 'test']}}
    (ROOT / 'validation_report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(report, ensure_ascii=False))


if __name__ == '__main__':
    main()
