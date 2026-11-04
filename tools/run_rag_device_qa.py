"""Run the existing headless Android RAG probe and restore radio settings."""
import argparse
import json
import subprocess
import uuid
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--adb', required=True)
    parser.add_argument('--serial', required=True)
    parser.add_argument('--entry', choices=['ragDeviceProbe', 'mlDeviceProbe', 'optionalModelDeviceProbe'], default='ragDeviceProbe')
    parser.add_argument('--output', default='output/rag-device-qa')
    args = parser.parse_args()
    out = Path(args.output)
    out.mkdir(parents=True, exist_ok=True)
    package = 'com.superkid.military.military_maintenance'
    def adb(*words, timeout=30):
        result = subprocess.run([args.adb, '-s', args.serial, *words],
                                capture_output=True, text=True, timeout=timeout)
        if result.returncode:
            raise RuntimeError(result.stderr)
        return result.stdout
    keys = ['airplane_mode_on', 'wifi_on', 'mobile_data']
    before = {k: adb('shell', 'settings', 'get', 'global', k).strip() for k in keys}
    run_id = uuid.uuid4().hex
    if not all(v in ['0', '1'] for v in before.values()):
        raise ValueError('Record and review non-binary radio settings before testing')
    (out / 'network-before.json').write_text(json.dumps(before, indent=2))
    try:
        adb('shell', 'cmd', 'connectivity', 'airplane-mode', 'enable')
        adb('shell', 'svc', 'wifi', 'disable')
        adb('shell', 'svc', 'data', 'disable')
        (out / 'offline-routes.txt').write_text(adb('shell', 'ip', 'route', 'show', 'table', 'all'))
        adb('shell', 'am', 'force-stop', package)
        log = adb('shell', 'am', 'instrument', '-w', '-e', 'entry', args.entry,
                  '-e', 'qaRunId', run_id, '-e', 'threads', '2',
                  f'{package}.test/{package}.RagInstrumentation',
                  timeout=660 if args.entry == 'optionalModelDeviceProbe' else 240)
        (out / 'instrumentation.log').write_text(log)
        report = json.loads(adb('exec-out', 'run-as', package, 'cat', 'files/rag-probe-result.json'))
        (out / 'device-result.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
        if report.get('qaRunId') != run_id or report.get('diagnosticEntry') != args.entry:
            raise RuntimeError('Diagnostic result does not belong to this run')
    finally:
        adb('shell', 'cmd', 'connectivity', 'airplane-mode',
            'enable' if before['airplane_mode_on'] == '1' else 'disable')
        adb('shell', 'svc', 'wifi', 'enable' if before['wifi_on'] == '1' else 'disable')
        adb('shell', 'svc', 'data', 'enable' if before['mobile_data'] == '1' else 'disable')
        after = {k: adb('shell', 'settings', 'get', 'global', k).strip() for k in keys}
        (out / 'network-after.json').write_text(json.dumps(after, indent=2))
        if after != before:
            raise RuntimeError('Radio settings did not restore; see network-after.json')
    print(json.dumps({k: report.get(k) for k in [
        'status', 'functionalStatus', 'physicalDevice', 'tokenizerParityCases',
        'orderedEvidenceRanksEqual', 'unloadConfirmed', 'workerRecovery',
        'predictionCases', 'classificationCases', 'predictionMaxAbsError',
        'classificationMaxAbsError']}, ensure_ascii=False))
    return 0 if report.get('status') == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
