"""Summarize a private flow result without adding independently sampled process maxima."""
import argparse
import hashlib
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', required=True, help='private run directory')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    directory = Path(args.run).resolve()
    if not directory.is_relative_to((root / 'private').resolve()):
        raise ValueError('results must stay in private')
    path = directory / 'emulator-or-device-result.json'
    raw = json.loads(path.read_text(encoding='utf-8-sig'))
    if raw['status'] != 'passed':
        raise ValueError('flow failed')
    report = {k: raw.get(k) for k in ('platform', 'physicalDevice', 'device', 'requestedThreads')}
    report['moduleName'] = '규칙 기반 잔여 정비거리 + 정비기록 분류'
    report['rawSha256'] = hashlib.sha256(path.read_bytes()).hexdigest()
    report['runMetadata'] = json.loads((directory / 'run-metadata.json').read_text(encoding='utf-8-sig'))
    report['flows'] = []
    for flow in raw['flows']:
        samples = [s for s in flow['memory']['samples'] if s['validPair'] and s['samePhase']]
        if not samples:
            raise ValueError('no stable paired samples')
        for s in samples:
            if s['pairedTotalPssKb'] != s['ui']['pssKb'] + s['worker']['pssKb']:
                raise ValueError('invalid paired sum')
        peak = max(samples, key=lambda s: s['pairedTotalPssKb'])
        phase_max = {}
        for s in samples:
            name = s['phaseStart']
            phase_max[name] = max(phase_max.get(name, 0), s['pairedTotalPssKb'] / 1024)
        report['flows'].append({
            **{k: flow[k] for k in ('withLlm', 'wallTotalMs', 'userConfirmationWaitMs', 'excludingUserWaitMs', 'measurementControlMs', 'stages', 'modelEvents', 'recordSaved', 'photo', 'confirmation', 'modelState', 'outputs')},
            'stablePairCount': len(samples),
            'sampleIntervalMs': 500,
            'sampledMaxPairedPssMiB': peak['pairedTotalPssKb'] / 1024,
            'atSampledMax': {'phase': peak['phaseStart'], 'uiMiB': peak['ui']['pssKb'] / 1024,
                             'workerMiB': peak['worker']['pssKb'] / 1024,
                             'windowMs': peak['windowMs'], 'midpointSkewMs': peak['midpointSkewMs']},
            'maxStableWindowMs': max(s['windowMs'] for s in samples),
            'maxStableMidpointSkewMs': max((s['midpointSkewMs'] for s in samples if s['midpointSkewMs'] is not None), default=None),
            'sampledMaxByPhaseMiB': phase_max,
        })
    report['limits'] = [
        'One observation per arm; no P50/P95 distribution claim',
        'Public stored photo, scripted manual selections and simulated confirmation wait',
        'Database/fixtures and runtime initialization before photo acquisition excluded',
        'Cold model sessions, warm application and filesystem caches',
        'Includes model load/infer/unload and measurement overhead; PSS sampled every 500ms',
        'Fresh self-PSS per process in one bounded request window, not exactly simultaneous or true peak',
        'Emulator/debug/headless results are not physical tablet performance or minimum RAM evidence',
    ]
    (directory / 'flow-summary.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps([{k: f[k] for k in ('withLlm', 'wallTotalMs', 'userConfirmationWaitMs', 'excludingUserWaitMs', 'sampledMaxPairedPssMiB', 'atSampledMax')} for f in report['flows']], ensure_ascii=False))


if __name__ == '__main__':
    main()
