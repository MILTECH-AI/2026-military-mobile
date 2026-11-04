"""Create explicitly fictional RAG input, never real maintenance guidance."""
import argparse
import hashlib
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', default='private/qa-rag')
    args = parser.parse_args()
    out = Path(args.output).resolve()
    if not out.is_relative_to(Path('private').resolve()):
        raise ValueError('QA bundles must remain under private/')
    out.mkdir(parents=True, exist_ok=True)
    texts = [
        '가상 시험 전용 문장입니다. 실제 정비 지침이 아닙니다. 일반 조건의 오일필터 교환 주기는 시험값 10000km 또는 12개월입니다.',
        '가상 시험 전용 문장입니다. 실제 정비 지침이 아닙니다. 가혹 조건의 오일필터 교환 주기는 시험값 5000km 또는 6개월입니다.',
        '오일 필터를 분리하는 가상 절차는 가상 부품 표식을 확인하고 시험 기록을 작성하는 것입니다. 가상 시험 전용 문장이며 실제 정비 절차가 아닙니다.',
    ]
    source = '\n\n'.join(texts) + '\n'
    filename = 'QA-SYNTHETIC-OIL-FILTER.txt'
    (out / filename).write_text(source, encoding='utf-8')
    digest = hashlib.sha256(source.encode()).hexdigest()
    def ref(page):
        return {'file': filename, 'page': page, 'sha256': digest,
                'location': f'가상 QA 문단 {page}, 실제 지침 아님'}
    evidence = [{
        'id': name, 'model': '가상 렉스턴 2023 시험차', 'part': '오일필터',
        'symptoms': '', 'title': f'가상 QA {label}, 실제 지침 아님',
        'location': f'가상 문단 {i}', 'text': text,
        'conceptId': 'QA-OIL-FILTER', 'sourceRef': ref(i),
    } for i, (name, label, text) in enumerate(zip(
        ['OIL-EVIDENCE-NORMAL', 'OIL-EVIDENCE-SEVERE', 'OIL-EVIDENCE-PROCEDURE'],
        ['일반 기준', '가혹 기준', '분리 절차'], texts), 1)]
    bundle = {
        'format': 'maintenance-knowledge', 'version': 1, 'id': 'QA-RAG-FICTIONAL-001',
        'evidence': evidence,
        'knowledge': {
            'concepts': [{'id': 'QA-OIL-FILTER', 'name': '오일필터',
                          'aliases': ['오일 필터', 'oil_filter']}],
            'skus': [], 'pending': [],
            'templates': [{
                'id': 'QA-OIL-CYCLE', 'conceptId': 'QA-OIL-FILTER',
                'requiresClarification': False, 'applicabilityNote': '가상 QA 전용, 실차 적용 금지',
                'normal': {'km': 10000, 'months': 12, 'note': '가상 시험값', 'sourceRef': ref(1)},
                'severe': {'km': 5000, 'months': 6, 'note': '가상 시험값', 'sourceRef': ref(2)},
            }],
        },
    }
    (out / 'knowledge.json').write_text(json.dumps(bundle, ensure_ascii=False, indent=2)+'\n')
    print(out / 'knowledge.json')


if __name__ == '__main__':
    main()
