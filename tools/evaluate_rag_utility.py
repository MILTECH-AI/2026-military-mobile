"""Local paired RAG evaluation. Never fills the team's questions or treats gate acceptance as utility.

Prepare: --questions private/.../questions-template.json --output private/.../prepared
Score: use --questions <installed prepared/questions.json>, add --result
  private/.../emulator-or-device-result.json --metadata <same run/run-metadata.json>
  [--feedback private/...json]
Run the prepared packet with run_embedding_probe.ps1 -Entry ragUtilityDeviceProbe
  -UtilityQuestions <prepared/questions.json> -LlmModel <local.gguf> -Serial <explicit serial>.
All derived data stays below this repository's private directory.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PRIVATE = (ROOT / 'private').resolve()


def private_path(value):
    path = Path(value).resolve()
    if not path.is_relative_to(PRIVATE):
        raise ValueError('inputs and outputs must remain in private')
    return path


def read(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))


def write(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding='utf-8')


def validated(packet):
    questions = packet['questions']
    if len({q['id'] for q in questions}) != len(questions):
        raise ValueError('duplicate question ID')
    sources = {s['evidenceId']: s['sourceRef'] for s in packet['sourceCatalog']}
    ready = [q for q in questions if q.get('reviewedAgainstOriginal') is True]
    for q in ready:
        if not q['question'].strip() or q['selectedUnitPolicy'] not in ('unselected', 'normal', 'severe'):
            raise ValueError('incomplete reviewed question')
        if q['expectedBehavior'] not in ('rule_value', 'evidence_reference', 'clarification', 'no_evidence'):
            raise ValueError('expectedBehavior required')
        gold = q['goldEvidence']
        if (not gold) != (q['expectedBehavior'] == 'no_evidence'):
            raise ValueError('gold evidence required except no_evidence')
        for g in gold:
            ref = sources[g['evidenceId']]
            if ref['file'] != g['file'] or ref['page'] != g['pdfPage']:
                raise ValueError('gold source mismatch')
        if not set(q['mustRankFirst']) <= {g['evidenceId'] for g in gold}:
            raise ValueError('mustRankFirst must be a gold ID')
    return ready


def ratio(values):
    return sum(values) / len(values) if values else None


def percentile(values, p):
    if not values:
        return None
    values = sorted(values)
    # Nearest rank, raw observations retained; not an SLO or physical-device estimate.
    return values[max(0, math.ceil(p * len(values)) - 1)]


def score(questions, result, feedback=None):
    if result.get('status') != 'passed' or result.get('design') != 'shared_retrieval_prefix':
        raise ValueError('successful shared-prefix measurement required')
    cases = result['cases']
    by_id = {q['id']: q for q in questions}
    if len(cases) != len(by_id) or {c['id'] for c in cases} != set(by_id):
        raise ValueError('result must contain each reviewed question exactly once')
    positive, negative, citations, first = [], [], [], []
    reasons = {}
    rows = []
    for c in cases:
        q = by_id[c['id']]
        gold = {g['evidenceId'] for g in q['goldEvidence']}
        ids = c['retrievedIds']
        if len(ids) != len(set(ids)) or len(ids) > 5 or not c['ruleValuesUnchanged']:
            raise ValueError('invalid retrieval or modified rule values')
        if not set(c['summaryCitationIds']) <= set(ids[:2]):
            raise ValueError('summary cites outside its supplied two sources')
        # Validate the measured source positions again, not just IDs.
        measured = {s['id']: s['sourceRef'] for s in c['retrievedSources']}
        for g in q['goldEvidence']:
            if g['evidenceId'] in measured:
                ref = measured[g['evidenceId']]
                if ref['file'] != g['file'] or ref['page'] != g['pdfPage']:
                    raise ValueError('measured source mismatch')
        row = {'id': c['id'], 'hasGold': bool(gold)}
        if gold:
            positive.append(c)
            row.update({f'hitAt{k}': bool(gold & set(ids[:k])) for k in (1, 3, 5)})
            row['recallAt5'] = len(gold & set(ids)) / len(gold)
            if c['automaticGateAccepted']:
                citations.append(bool(gold & set(c['summaryCitationIds'])))
            if q['mustRankFirst']:
                first.append(bool(ids) and ids[0] in q['mustRankFirst'])
        else:
            negative.append(bool(ids))
        reason = c.get('summaryReason') or c['summaryMode']
        reasons[reason] = reasons.get(reason, 0) + 1
        rows.append(row)
    raw_times = {arm: [c[key] for c in cases] for arm, key in (
        ('retrieval_only', 'retrievalOnlyMs'), ('retrieval_plus_summary', 'withSummaryMs'))}
    for values in raw_times.values():
        if any(not isinstance(v, (int, float)) or not math.isfinite(v) or v < 0 for v in values):
            raise ValueError('invalid timing')
    human = {'retrieval_only': [], 'retrieval_plus_summary': []}
    if feedback is not None:
        seen = set()
        for f in feedback['cases']:
            if f['id'] not in by_id or f['id'] in seen:
                raise ValueError('unknown or duplicate feedback ID')
            seen.add(f['id'])
            for arm in human:
                value = f[arm]['userAccepted']
                if value is not None and not isinstance(value, bool):
                    raise ValueError('human adoption must be true/false/null')
                if value is not None:
                    human[arm].append(value)
    positive_rows = [r for r in rows if r['hasGold']]
    return {
        'status': 'measured' if cases else 'awaiting_team_questions',
        'count': len(cases), 'platform': result.get('platform'),
        'physicalDevice': result.get('physicalDevice'),
        'commonRetrieval': {**{f'hitAt{k}': ratio([r[f'hitAt{k}'] for r in positive_rows]) for k in (1, 3, 5)},
                            'recallAt5': ratio([r['recallAt5'] for r in positive_rows]),
                            'positiveCount': len(positive), 'mustRankFirstRate': ratio(first),
                            'negativeReturnedEvidenceRate': ratio(negative), 'negativeCount': len(negative)},
        'referencesVisibleInBothArms': True,
        'acceptedSummaryGoldCitationRate': ratio(citations),
        'automaticGateAdoption': ratio([c['automaticGateAccepted'] for c in cases]),
        'gateAdoptionAmongExecuted': ratio([c['automaticGateAccepted'] for c in cases if c['generationExecuted']]),
        'generationExecutedCount': sum(c['generationExecuted'] for c in cases),
        'summaryOutcomes': reasons,
        'humanAdoption': {arm: {'reviewedCount': len(v), 'rate': ratio(v)} for arm, v in human.items()},
        'latencyMs': {arm: {'count': len(v), 'p50': percentile(v, .5), 'p95': percentile(v, .95), 'raw': v} for arm, v in raw_times.items()},
        'cases': rows,
        'limitations': ['shared retrieval prefix, not independent randomized trials',
                       'gold citation inclusion is not sentence relevance or entailment accuracy',
                       'automatic citation gate acceptance is not human utility',
                       'emulator latency is not physical-device latency'],
    }


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--questions', required=True)
    p.add_argument('--output', required=True)
    p.add_argument('--result')
    p.add_argument('--feedback')
    p.add_argument('--metadata')
    args = p.parse_args()
    source = private_path(args.questions)
    packet = read(source)
    ready = validated(packet)
    output = private_path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    # Copy only, never replace the team's editable packet.
    target = output / 'questions.json'
    if target.resolve() == source:
        raise ValueError('output must differ from original questions')
    write(target, packet)
    status = {'status': 'ready' if ready else 'awaiting_team_questions',
              'total': len(packet['questions']), 'reviewed': len(ready),
              'sourceSha256': hashlib.sha256(source.read_bytes()).hexdigest(),
              'design': 'shared_retrieval_prefix', 'metrics': None}
    if args.result:
        result_path = private_path(args.result)
        if not args.metadata:
            raise ValueError('run metadata required to bind questions to measured APK')
        metadata = read(private_path(args.metadata))
        if metadata.get('questionsSha256') != hashlib.sha256(source.read_bytes()).hexdigest():
            raise ValueError('question packet differs from the installed measurement input')
        status['runMetadata'] = metadata
        status['metrics'] = score(ready, read(result_path), read(private_path(args.feedback)) if args.feedback else None)
        status['resultSha256'] = hashlib.sha256(result_path.read_bytes()).hexdigest()
    write(output / 'evaluation.json', status)
    feedback_path = output / 'human-feedback.json'
    if not feedback_path.exists():
        write(feedback_path, {'purpose': 'optional human utility review, separate from citation gate', 'cases': [
            {'id': q['id'], **{arm: {'userAccepted': None, 'note': ''} for arm in ('retrieval_only', 'retrieval_plus_summary')}} for q in ready]})
    print(json.dumps({'status': status['status'], 'total': status['total'], 'reviewed': len(ready)}))


if __name__ == '__main__':
    main()
