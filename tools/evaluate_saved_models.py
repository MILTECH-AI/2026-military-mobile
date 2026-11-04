"""Evaluate existing public synthetic models; never fit or overwrite weights."""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np

from train_local_models import classify, metrics, read, sigmoid, text_metrics, write


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', default='output/model-qa')
    args = parser.parse_args()
    out = Path(args.output)
    model_file = Path('assets/models/prediction.json')
    classifier_file = Path('assets/models/classification.json')
    model = json.loads(model_file.read_text())
    classifier = json.loads(classifier_file.read_text())
    rows = read('prediction', 'test')
    names = model['featureNames']
    x = np.array([[r['features'][f] for f in names] for r in rows], dtype=float)
    y = np.array([r['label']['correctiveMaintenanceNextMonth'] for r in rows])

    def predict(raw):
        normalized = np.clip((raw - model['mean']) / model['scale'],
                             -model['standardizedClip'], model['standardizedClip'])
        return sigmoid(normalized @ np.array(model['weights']) + model['bias'])

    probabilities = predict(x)
    assert np.isfinite(probabilities).all()
    assert ((probabilities >= 0) & (probabilities <= 1)).all()
    threshold = model['validationThreshold']
    future = np.array([r['observedAt'] >= '2026-01-01' for r in rows])
    rng = np.random.default_rng(20261010)
    noisy = x.copy()
    noisy[:, names.index('monthlyDistanceKm')] *= rng.uniform(.85, 1.15, len(y))
    noisy[:, names.index('monthlyFuelL')] *= rng.uniform(.9, 1.1, len(y))
    noisy[:, names.index('litersPer100Km')] = (
        100 * noisy[:, names.index('monthlyFuelL')] / noisy[:, names.index('monthlyDistanceKm')])
    text_rows = read('classification', 'test')
    noisy_text = [
        {**r, 'input': {'part': '', 'description': ''.join(
            c for i, c in enumerate(r['input']['description']) if i % 13 != 7)}}
        for r in text_rows
    ]
    parity_text = [
        {label: classify(head, **r['input'])
         for label, head in classifier['heads'].items()}
        for r in text_rows
    ]
    scenarios = {}
    for scenario in sorted({r['scenario'] for r in rows}):
        mask = np.array([r['scenario'] == scenario for r in rows])
        scenarios[scenario] = metrics(y[mask], probabilities[mask], threshold)
    report = {
        'status': 'completed', 'scope': 'public synthetic held-out test data only',
        'weightsChanged': False, 'threshold': threshold,
        'sha256': {str(p): hashlib.file_digest(p.open('rb'), 'sha256').hexdigest()
                   for p in [model_file, classifier_file]},
        'prediction': metrics(y, probabilities, threshold),
        'unseenVehiclesFuture2026': metrics(y[future], probabilities[future], threshold),
        'measurementNoiseStress': metrics(y, predict(noisy), threshold),
        'scenarios': scenarios,
        'classification': {
            label: {'clean': text_metrics(text_rows, head, label),
                    'missingPartAndDeletedCharacters': text_metrics(noisy_text, head, label)}
            for label, head in classifier['heads'].items()
        },
        'limits': ['Synthetic labels do not establish real vehicle failure accuracy.',
                   'Finite synthetic text templates do not establish field text accuracy.'],
    }
    write(out / 'metrics.json', report)
    write(out / 'parity.json', {
        'modelVersions': {'prediction': model['version'], 'classification': classifier['version']},
        'prediction': probabilities.tolist(), 'classification': parity_text,
    })
    write(out / 'device-probes.json', {
        'format': 'synthetic-model-qa', 'isSynthetic': True,
        'modelVersions': {'prediction': model['version'], 'classification': classifier['version']},
        'prediction': [{'features': r['features'], 'expected': float(p)}
                       for r, p in zip(rows, probabilities)],
        'classification': [{**r['input'], 'expected': expected}
                           for r, expected in zip(text_rows, parity_text)],
    })
    print(json.dumps({'predictionRows': len(rows), 'classificationRows': len(text_rows),
                      'auc': report['prediction']['rocAuc'], 'f1': report['prediction']['f1']}))


if __name__ == '__main__':
    main()
