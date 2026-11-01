"""Local descriptive statistics for repeated complete-flow emulator observations."""
import argparse
import hashlib
import json
import math
import re
from pathlib import Path


def stats(values):
    if not values:
        return {'n': 0, 'p50': None, 'p95': None, 'min': None, 'max': None, 'raw': []}
    values = sorted(values)
    if any(not math.isfinite(v) or v < 0 for v in values):
        raise ValueError('invalid numeric observation')
    return {'n': len(values), 'p50': values[math.ceil(.50*len(values))-1],
            'p95': values[math.ceil(.95*len(values))-1], 'min': values[0], 'max': values[-1], 'raw': values}


def read(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))


def paired_memory(flow):
    valid = [s for s in flow['memory']['samples'] if s['validPair'] and s['samePhase']]
    if not valid:
        raise ValueError('no stable paired PSS samples')
    for s in valid:
        if s['ui']['pssKb'] + s['worker']['pssKb'] != s['pairedTotalPssKb']:
            raise ValueError('PSS is not a paired sum')
    peak = max(valid, key=lambda s: s['pairedTotalPssKb'])
    return {'sampledPeakMiB': peak['pairedTotalPssKb']/1024,
            'sampledWorkerMaxMiB': max(s['worker']['pssKb'] for s in valid)/1024,
            'uiAtPeakMiB': peak['ui']['pssKb']/1024,
            'workerAtPeakMiB': peak['worker']['pssKb']/1024,
            'phase': peak['phaseStart'], 'windowMs': peak['windowMs'],
            'midpointSkewMs': peak['midpointSkewMs'],
            'validPairs': len(valid), 'maxWindowMs': max(s['windowMs'] for s in valid),
            'maxMidpointSkewMs': max((s['midpointSkewMs'] for s in valid if s['midpointSkewMs'] is not None), default=None),
            'observedWorkerThreads': sorted({s['worker']['threads'] for s in valid if s['worker'].get('threads', 0) > 0})}


def summarize(directory):
    plan = read(directory/'matrix-plan.json')
    profiles = []
    sources = {}
    for ram in plan['ramMiB']:
        baseline_path = directory/f'ram-{ram}'/'installation-qualification'/'baseline'/'baseline.json'
        memory_context = {}
        if baseline_path.exists():
            for line in read(baseline_path)['checks']['memory']['output']:
                match = re.match(r'(MemTotal|MemAvailable|SwapTotal|SwapFree):\s+(\d+)\s+kB', line)
                if match:
                    memory_context[match[1]] = int(match[2])
        for threads in plan['threads']:
            folder = directory/f'ram-{ram}'/f'threads-{threads}'
            measured, warmup, failures = [], [], []
            for meta_path in sorted(folder.glob('*/metadata.json')):
                meta = read(meta_path)
                if meta['appSha256'] != plan['appSha256'] or meta['testSha256'] != plan['testSha256']:
                    raise ValueError('mixed APKs')
                result_path = meta_path.parent/'result.json'
                if not result_path.exists():
                    if meta['phase'] == 'measured': failures.append({'run': meta['run'], 'reason': 'no_result'})
                    continue
                result = read(result_path)
                sources[str(result_path.relative_to(directory))] = hashlib.sha256(result_path.read_bytes()).hexdigest()
                device = result.get('device', {})
                valid_config = (result.get('physicalDevice') is False and device.get('api') == 33
                                and device.get('cores') == 4 and result.get('requestedThreads') == threads
                                and (ram-256)*1024**2 <= device.get('ramBytes', 0) <= (ram+64)*1024**2)
                if not valid_config:
                    if meta['phase'] == 'measured': failures.append({'run': meta['run'], 'reason': 'configuration_unverified'})
                    continue
                if meta['phase'] == 'warmup':
                    warmup.append({'run': meta['run'], 'status': result['status']})
                    continue
                if result['status'] != 'passed':
                    failures.append({'run': meta['run'], 'reason': result.get('error', 'flow_failed')})
                measured.append((meta, result))
            arms = {}
            for with_llm, name in [(False, 'retrieval_only'), (True, 'retrieval_plus_summary')]:
                values, memories, stage_values, native_values, outcomes = [], [], {}, {}, {}
                devices = []
                for meta, result in measured:
                    matches = [f for f in result.get('flows', []) if f['withLlm'] is with_llm]
                    if len(matches) > 1:
                        raise ValueError('duplicate flow arm')
                    if not matches:
                        continue
                    f = matches[0]
                    if not f['recordSaved']:
                        raise ValueError('maintenance not saved')
                    memory = paired_memory(f)
                    # A short inference can finish between 500ms samples. Absence is
                    # unobserved, not proof of a mismatch or zero inference threads.
                    if memory['observedWorkerThreads'] and memory['observedWorkerThreads'] != [threads]:
                        raise ValueError('native worker threads differ from requested configuration')
                    memories.append({'run': meta['run'], **memory})
                    values.append(f)
                    devices.append(result['device']['ramBytes'])
                    for s in f['stages']:
                        stage_values.setdefault(s['name'], []).append(s['durationMs'])
                    for model in ('visionTimingsMs', 'embeddingTimingsMs'):
                        for operation, value in f['outputs'][model].items():
                            native_values.setdefault(f'{model}/{operation}', []).append(value)
                    for model, field in [('llm', 'summary'), ('classification', 'systemProposal')]:
                        if field in f['outputs']:
                            for operation, value in (f['outputs'][field]['timingsMs'] or {}).items():
                                native_values.setdefault(f'{model}/{operation}', []).append(value)
                    mode = f['outputs'].get('summary', {}).get('mode', 'retrieval_only')
                    outcomes[mode] = outcomes.get(mode, 0) + 1
                n = len(values)
                arms[name] = {'validResponses': n, 'minimumTarget': plan['measuredRuns'],
                              'sufficient': n >= plan['measuredRuns'],
                              'wallMs': stats([f['wallTotalMs'] for f in values]),
                              'excludingUserWaitMs': stats([f['excludingUserWaitMs'] for f in values]),
                              'simulatedUserWaitMs': stats([f['userConfirmationWaitMs'] for f in values]),
                              'sampledPeakPairedPssMiB': stats([m['sampledPeakMiB'] for m in memories]),
                              'memoryObservations': memories, 'reportedRamBytes': sorted(set(devices)),
                              'runsWithPositiveThreadSamples': sum(bool(m['observedWorkerThreads']) for m in memories),
                              'stageMs': {k: stats(v) for k, v in stage_values.items()},
                              'nativeModelMs': {k: stats(v) for k, v in native_values.items()},
                              'summaryOutputTokens': stats([f['outputs']['summary']['outputTokens'] for f in values
                                                            if isinstance(f['outputs'].get('summary', {}).get('outputTokens'), (int, float))]),
                              'summaryOutcomes': outcomes}
            profiles.append({'configuredRamMiB': ram, 'threads': threads, 'warmups': warmup,
                             'baselineGuestMeminfoKb': memory_context,
                             'harnessHostElapsedMs': stats([meta['elapsedHostMs'] for meta, _ in measured]),
                             'warmupsSufficient': len(warmup) >= plan['warmupRuns'] and all(w['status'] == 'passed' for w in warmup),
                             'completePairResults': len(measured), 'failures': failures, 'arms': arms})
    complete = all(p['warmupsSufficient'] and not p['failures'] and all(a['sufficient'] for a in p['arms'].values()) for p in profiles)
    return {'status': 'passed' if complete else 'incomplete_or_failed', 'moduleName': plan['moduleName'],
            'platform': 'android-emulator', 'physicalDevice': False, 'plan': plan, 'profiles': profiles,
            'sourceHashes': sources,
            'limitations': ['one fixed photo, question and scripted manual selections',
                           'module times are phases within complete flows, not independent isolated-module benchmarks',
                           'cold model sessions and force-stopped app; file caches are warm',
                           'RAM settings run sequentially and host background load is not controlled; timing differences cannot be attributed solely to RAM',
                           'nearest-rank P95 with n=10 is the observed maximum',
                           'fresh PSS pairs are bounded-window samples, not exact simultaneous or true peaks',
                           'short model sessions can finish between samples; missing thread/PSS samples are unobserved, not zero',
                           'not ARM/physical CPU/GPU/MDM/camera/thermal/battery validation',
                           'guest swap is enabled; baseline swap capacity is recorded, not continuous swap consumption',
                           'no actual OOM exhaustion or lower-RAM physical support guarantee']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', required=True)
    args = parser.parse_args()
    directory = Path(args.run).resolve()
    private = Path(__file__).resolve().parents[1]/'private'
    if not directory.is_relative_to(private.resolve()):
        raise ValueError('results must remain in private')
    report = summarize(directory)
    (directory/'matrix-summary.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    if report['status'] == 'passed':
        worker_max = max(m['sampledWorkerMaxMiB'] for p in report['profiles']
                         for m in p['arms']['retrieval_plus_summary']['memoryObservations'])
        policy = {
            'status': 'engineering_draft_not_physical_minimum',
            'moduleName': report['moduleName'], 'source': 'matrix-summary.json',
            'scope': 'current oil-filter bundle, one fixed public photo and question; not full-catalog scale or relevance validation',
            'applyToAppAutomatically': False,
            'basic': {'recommendedStartingNominalRamGiB': 3, 'threads': 2, 'defaultMode': 'retrieval_only',
                      'functions': ['embedding and keyword search', 'lightweight Vision adapter',
                                    'rule-based remaining service distance', 'record classification proposal', 'linked lookup and maintenance save'],
                      'below3GiB': 'not tested, not declared unsupported'},
            'optionalLlm': {'recommendedStartingNominalRamGiB': 4, 'minimumApiFromExistingBuild': 28,
                            'abi': '64-bit required; this matrix tested x86_64 only', 'defaultEnabled': False,
                            'activation': 'explicit user request only',
                            'draftAvailableMemoryReserveMiB': math.ceil(2*worker_max/256)*256,
                            'reserveDerivation': {'largestObservedWorkerPssMiB': worker_max,
                                                  'safetyFactor': 2, 'roundUpMiB': 256,
                                                  'status': 'conservative engineering assumption, not a tested admission threshold'},
                            'fallback': 'retrieval_only on low-memory signal, worker failure or citation rejection'},
            'detectedTotalRamHardCutoffBytes': None,
            'cautions': ['nominal RAM is not Android MemTotal; do not compare 4GiB literally with detected MemTotal',
                         '3GiB emulator LLM runs also passed; 4GiB recommendation adds engineering margin, not a demonstrated failure boundary',
                         'PSS sampling is not an allocation bound; reserve is provisional and not physically validated',
                         'real OOM exhaustion and ARM hardware performance remain unmeasured',
                         'RAM configurations were sequential; host load and guest swap prevent causal speed claims'],
        }
        (directory/'provisional-policy.json').write_text(json.dumps(policy, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps({'status': report['status'], 'profiles': [
        {'ramMiB': p['configuredRamMiB'], 'threads': p['threads'], 'failures': len(p['failures']),
         'arms': {k: {'n': a['validResponses'], 'p50ms': a['excludingUserWaitMs']['p50'], 'p95ms': a['excludingUserWaitMs']['p95'], 'sampledPssMaxMiB': a['sampledPeakPairedPssMiB']['max']} for k, a in p['arms'].items()}}
        for p in report['profiles']]}))


if __name__ == '__main__':
    main()
