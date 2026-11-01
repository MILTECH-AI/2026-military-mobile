"""Train compact, offline models using only synthetic train/validation/test files."""
import os
os.environ.setdefault('OPENBLAS_NUM_THREADS', '1')
import json
import hashlib
import math
import time
from collections import Counter
from pathlib import Path
import numpy as np

ROOT = Path('data/mock')
MODEL_OUT = Path('assets/models')
REPORT_OUT = Path('output/models')


def read(task, split):
    return [json.loads(line) for line in (ROOT / task / f'{split}.jsonl').read_text(encoding='utf-8').splitlines()]


def read_full_prediction():
    with (ROOT / 'training.jsonl').open(encoding='utf-8') as stream:
        for line in stream:
            yield json.loads(line)


def sigmoid(x):
    return 1 / (1 + np.exp(-np.clip(x, -40, 40)))


def auc(y, p):
    order = np.argsort(p, kind='stable')
    sorted_p = p[order]
    ranks = np.empty(len(y), dtype=float)
    i = 0
    while i < len(y):
        j = i + 1
        while j < len(y) and sorted_p[j] == sorted_p[i]:
            j += 1
        ranks[order[i:j]] = (i + 1 + j) / 2
        i = j
    positives = y.sum()
    return float((ranks[y == 1].sum() - positives * (positives + 1) / 2) / (positives * (len(y) - positives)))


def average_precision(y, p):
    order = np.argsort(-p, kind='stable')
    tp = fp = 0
    previous_recall = score = 0.0
    i = 0
    while i < len(y):
        j = i + 1
        while j < len(y) and p[order[j]] == p[order[i]]:
            j += 1
        positives = int(y[order[i:j]].sum())
        tp += positives
        fp += j - i - positives
        recall = tp / y.sum()
        score += (recall - previous_recall) * tp / (tp + fp)
        previous_recall = recall
        i = j
    return float(score)


def metrics(y, p, threshold):
    guessed = p >= threshold
    tp, fp = int(((y == 1) & guessed).sum()), int(((y == 0) & guessed).sum())
    tn, fn = int(((y == 0) & ~guessed).sum()), int(((y == 1) & ~guessed).sum())
    precision, recall = tp / max(1, tp + fp), tp / max(1, tp + fn)
    q = np.clip(p, 1e-9, 1 - 1e-9)
    return {'rocAuc': auc(y, p), 'averagePrecision': average_precision(y, p),
        'logLoss': float(-(y * np.log(q) + (1-y) * np.log(1-q)).mean()),
        'brierScore': float(((p-y)**2).mean()), 'accuracy': (tp+tn)/len(y),
        'precision': precision, 'recall': recall, 'f1': 2*precision*recall/max(1e-9, precision+recall),
        'confusion': {'tp': tp, 'fp': fp, 'tn': tn, 'fn': fn}, 'rows': len(y)}


def tokens(part, description):
    text = ''.join((part + ' ' + description).lower().split())
    return Counter(text[i:i+n] for n in [2, 3] for i in range(len(text)-n+1))


def train_text(rows, label):
    classes = sorted({r['label'][label] for r in rows})
    counts = {c: Counter() for c in classes}
    documents = Counter()
    for row in rows:
        c = row['label'][label]
        documents[c] += 1
        counts[c].update(tokens(**row['input']))
    total_counts = sum(counts.values(), Counter())
    vocab = sorted(t for t, count in total_counts.items() if count >= 3)
    priors = [math.log(documents[c]/len(rows)) for c in classes]
    denominators = [sum(counts[c][t] for t in vocab)+len(vocab) for c in classes]
    return {'classes': classes, 'logPriors': priors,
        'tokenLogProbabilities': {t: [math.log((counts[c][t]+1)/denominators[i])
            for i, c in enumerate(classes)] for t in vocab}}


def classify(head, part, description):
    counts = tokens(part, description)
    scores = np.array(head['logPriors'])
    known = 0
    for token, count in counts.items():
        weights = head['tokenLogProbabilities'].get(token)
        if weights:
            scores += count * np.array(weights)
            known += count
    probabilities = np.exp(scores - scores.max())
    probabilities /= probabilities.sum()
    chosen = int(probabilities.argmax())
    coverage = known / max(1, sum(counts.values()))
    confidence = float(probabilities[chosen])
    accepted = known >= 8 and coverage >= 0.2 and confidence >= 0.65
    return {'label': head['classes'][chosen] if accepted else None,
        'confidence': confidence, 'coverage': coverage}


def text_metrics(rows, head, label):
    matrix = Counter()
    predictions = []
    for row in rows:
        guess = classify(head, **row['input'])
        matrix[(row['label'][label], guess['label'])] += 1
        predictions.append(guess)
    correct = sum(matrix[(c, c)] for c in head['classes'])
    f1 = []
    for c in head['classes']:
        tp = matrix[(c, c)]
        fp = sum(n for (actual, predicted), n in matrix.items() if predicted == c and actual != c)
        fn = sum(n for (actual, predicted), n in matrix.items() if actual == c and predicted != c)
        f1.append(2*tp/max(1, 2*tp+fp+fn))
    return {'rows': len(rows), 'accuracy': correct/len(rows), 'macroF1': sum(f1)/len(f1),
        'abstentions': sum(p['label'] is None for p in predictions),
        'classes': head['classes']}


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def main():
    start = time.perf_counter()
    manifest = json.loads((ROOT/'manifest.json').read_text(encoding='utf-8'))
    names = manifest['featureNames']
    dataset = 'synthetic ' + manifest['datasetVersion']
    splits = {s: read('prediction', s) for s in ['train', 'validation', 'test']}
    # 2026 observations are never used for fitting or threshold selection.
    for s in ['train', 'validation']:
        splits[s] = [r for r in splits[s] if r['labelWindowEnd'] < '2026-01-01']
    x = {s: np.array([[r['features'][f] for f in names] for r in rows], dtype=float) for s, rows in splits.items()}
    y = {s: np.array([r['label']['correctiveMaintenanceNextMonth'] for r in rows], dtype=float) for s, rows in splits.items()}
    mean, scale = x['train'].mean(axis=0), x['train'].std(axis=0)
    scale[scale < 1e-9] = 1
    z = {s: np.clip((v-mean)/scale, -6, 6) for s, v in x.items()}
    trials, best = [], None
    for regularization in [0.0001, 0.001, 0.01, 0.05]:
        weights = np.zeros(len(names))
        bias = math.log(y['train'].mean()/(1-y['train'].mean()))
        for _ in range(1000):
            error = sigmoid(z['train'] @ weights + bias) - y['train']
            weights -= 0.12 * (z['train'].T @ error / len(error) + regularization*weights)
            bias -= 0.12 * error.mean()
        pv = sigmoid(z['validation'] @ weights + bias)
        report = metrics(y['validation'], pv, 0.5)
        trials.append({'regularization': regularization, 'validationLogLoss': report['logLoss']})
        if best is None or report['logLoss'] < best[0]:
            best = report['logLoss'], weights.copy(), float(bias), regularization
    _, weights, bias, regularization = best
    pv = sigmoid(z['validation'] @ weights + bias)
    choices = [(metrics(y['validation'], pv, float(t))['f1'], float(t)) for t in np.linspace(0.05, 0.5, 91)]
    threshold = max(choices)[1]
    model = {'version': 'rexton-local-2', 'trainedOn': dataset,
        'task': 'correctiveMaintenanceNextMonth', 'featureNames': names,
        'mean': mean.tolist(), 'scale': scale.tolist(), 'weights': weights.tolist(),
        'bias': bias, 'standardizedClip': 6, 'validationThreshold': threshold,
        'limitations': 'Synthetic maintenance-event estimate; not confirmed failure probability'}
    model['version'] += '-' + hashlib.sha256(json.dumps(model, sort_keys=True).encode()).hexdigest()[:12]
    write(MODEL_OUT/'prediction.json', model)
    numeric_report = {'algorithm': 'L2 logistic regression', 'epochs': 1000, 'trials': trials,
        'chosenRegularization': regularization, 'thresholdChosenOn': 'validation F1', 'threshold': threshold,
        'splits': {s: metrics(y[s], sigmoid(z[s] @ weights + bias), threshold) for s in splits},
        'constantBaselineTest': metrics(y['test'], np.full(len(y['test']), y['train'].mean()), threshold)}
    test_p = sigmoid(z['test'] @ weights + bias)
    numeric_report['scenarioTests'] = {}
    for scenario in sorted({r['scenario'] for r in splits['test']}):
        mask = np.array([r['scenario'] == scenario for r in splits['test']])
        numeric_report['scenarioTests'][scenario] = metrics(y['test'][mask], test_p[mask], threshold)
    future_mask = np.array([r['observedAt'] >= '2026-01-01' for r in splits['test']])
    numeric_report['unseenVehiclesFuture2026'] = metrics(y['test'][future_mask], test_p[future_mask], threshold)
    # Counterfactual sensitivity, not ground truth: same records, changed inputs.
    probes = []
    for i, row in enumerate(splits['test'][:100]):
        raw = x['test'][i].copy()
        raw[names.index('litersPer100Km')] += 2
        normalized = np.clip((raw-mean)/scale, -6, 6)
        probes.append(float(sigmoid(normalized @ weights + bias)) - float(test_p[i]))
    numeric_report['fuelDegradationSensitivity'] = {'rows': len(probes),
        'meanProbabilityChangeForPlus2LitersPer100Km': float(np.mean(probes)),
        'warning': 'Model response check only; not a causal real-world claim'}
    stress_rng = np.random.default_rng(20261010)
    stress_x = x['test'].copy()
    stress_x[:, names.index('monthlyDistanceKm')] *= stress_rng.uniform(0.85, 1.15, len(stress_x))
    stress_x[:, names.index('monthlyFuelL')] *= stress_rng.uniform(0.9, 1.1, len(stress_x))
    stress_x[:, names.index('litersPer100Km')] = 100 * stress_x[:, names.index('monthlyFuelL')] / stress_x[:, names.index('monthlyDistanceKm')]
    numeric_report['measurementNoiseStress'] = metrics(y['test'],
        sigmoid(np.clip((stress_x-mean)/scale, -6, 6) @ weights + bias), threshold)
    numeric_report['measurementNoiseDefinition'] = 'Held-out inputs perturbed: monthly distance +/-15%, monthly fuel +/-10%, derived fuel efficiency recomputed; original labels retained; no fitting or threshold tuning'
    text_splits = {s: read('classification', s) for s in splits}
    heads = {label: train_text(text_splits['train'], label) for label in ['system', 'maintenanceType']}
    text_model = {'version': 'rexton-text-2', 'trainedOn': dataset,
        'tokenizer': 'lowercase-remove-whitespace-char-2-3-grams', 'heads': heads,
        'minimumKnownTokens': 8, 'minimumCoverage': 0.2, 'minimumConfidence': 0.65}
    text_model['version'] += '-' + hashlib.sha256(json.dumps(text_model, sort_keys=True).encode()).hexdigest()[:12]
    write(MODEL_OUT/'classification.json', text_model)
    text_report = {label: {s: text_metrics(rows, heads[label], label) for s, rows in text_splits.items()} for label in heads}
    rough_text = []
    for r in text_splits['test']:
        # Remove part field and regularly delete characters from description.
        description = ''.join(c for i, c in enumerate(r['input']['description']) if i % 13 != 7)
        rough_text.append({**r, 'input': {'part': '', 'description': description}})
    for label, head in heads.items():
        text_report[label]['missingPartAndCharacterDeletionStress'] = text_metrics(rough_text, head, label)
    prediction_fixtures = [{'features': r['features'],
        'probability': float(sigmoid(z['test'][i:i+1] @ weights + bias)[0])} for i, r in enumerate(splits['test'][:20])]
    text_fixtures = [{**r['input'], 'expected': {label: classify(head, **r['input']) for label, head in heads.items()}}
        for r in text_splits['test'][:12]]
    text_fixtures.append({'part': '', 'description': 'xyz123 🟪🟪',
        'expected': {label: classify(head, '', 'xyz123 🟪🟪') for label, head in heads.items()}})
    app_fixtures = [{'vehicleId': r['vehicleId'], 'observedAt': r['observedAt'], 'features': r['features']}
        for r in read_full_prediction() if r['vehicleId'] in {f'MOCK-RX-{i:04}' for i in range(1, 6)}
        and r['observedAt'] == '2026-09-30']
    write(REPORT_OUT/'parity_fixtures.json', {'prediction': prediction_fixtures,
        'classification': text_fixtures, 'appSnapshots': app_fixtures})
    benchmark = z['test'][:100]
    bench_start = time.perf_counter()
    for _ in range(1000):
        sigmoid(benchmark @ weights + bias)
    report = {'dataset': dataset, 'numeric': numeric_report, 'text': text_report,
        'modelVersions': {'prediction': model['version'], 'classification': text_model['version']},
        'python100PredictionsMeanMs': (time.perf_counter()-bench_start),
        'trainingElapsedSeconds': time.perf_counter()-start,
        'evaluationRules': 'Train-only scaler/vocabulary; validation-only model and threshold selection; disjoint test vehicles; numeric train and validation label windows end before 2026; future 2026 test reported separately',
        'limits': ['Synthetic performance only', 'Classification uses finite part names/templates',
            'No vision or language-generation model trained', 'No Galaxy Tab hardware benchmark yet']}
    write(REPORT_OUT/'evaluation.json', report)
    previous = REPORT_OUT/'baseline-v2/evaluation.json'
    if previous.exists():
        old = json.loads(previous.read_text(encoding='utf-8'))
        write(REPORT_OUT/'comparison.json', {
            'previousDataset': old['dataset'], 'currentDataset': dataset,
            'previousTest': old['numeric']['splits']['test'],
            'currentTest': numeric_report['splits']['test'],
            'future2026Test': numeric_report['unseenVehiclesFuture2026'],
            'measurementNoiseStress': numeric_report['measurementNoiseStress'],
            'interpretation': 'Datasets and training periods differ; this measures a revised synthetic task, not improved performance on an unchanged real-world benchmark. Simulator latent wear and scenario names are excluded from model features.'})
    print(json.dumps({'predictionTest': numeric_report['splits']['test'],
        'baselineAuc': numeric_report['constantBaselineTest']['rocAuc'],
        'classificationTest': {label: r['test'] for label, r in text_report.items()},
        'trainingElapsedSeconds': report['trainingElapsedSeconds']}, ensure_ascii=False))


if __name__ == '__main__':
    main()
