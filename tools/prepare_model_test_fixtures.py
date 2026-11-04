"""Build public synthetic parity fixtures without training or changing models."""
import json
from pathlib import Path

import numpy as np

from train_local_models import classify, read, read_full_prediction, sigmoid, write


def main():
    model = json.loads(Path('assets/models/prediction.json').read_text())
    text = json.loads(Path('assets/models/classification.json').read_text())
    rows = read('prediction', 'test')[:20]
    raw = np.array([[r['features'][f] for f in model['featureNames']] for r in rows])
    normalized = np.clip(
        (raw - np.array(model['mean'])) / np.array(model['scale']),
        -model['standardizedClip'], model['standardizedClip'],
    )
    probabilities = sigmoid(normalized @ np.array(model['weights']) + model['bias'])
    inputs = [r['input'] for r in read('classification', 'test')[:12]]
    inputs.append({'part': '', 'description': 'xyz123 🟪🟪'})
    write(Path('test/fixtures/local_model_parity.json'), {
        'modelVersions': {'prediction': model['version'], 'classification': text['version']},
        'prediction': [
            {'features': r['features'], 'probability': float(p)}
            for r, p in zip(rows, probabilities)
        ],
        'classification': [
            {**r, 'expected': {label: classify(head, **r)
                              for label, head in text['heads'].items()}}
            for r in inputs
        ],
        'appSnapshots': [
            {k: r[k] for k in ['vehicleId', 'observedAt', 'features']}
            for r in read_full_prediction()
            if r['vehicleId'] in {f'MOCK-RX-{i:04}' for i in range(1, 6)}
            and r['observedAt'] == '2026-09-30'
        ],
    })


if __name__ == '__main__':
    main()
