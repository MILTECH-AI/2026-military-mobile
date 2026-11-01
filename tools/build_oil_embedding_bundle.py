"""Local-only oil-filter corpus builder. Never calls a remote inference service.

Set PYTHONPATH=.tools/rag-python and provision the public weights separately.
All source-derived outputs must remain under private/.
"""
import argparse
import hashlib
import json
import os
import time
import zipfile
from pathlib import Path

import numpy as np
import onnx
from onnx import helper, numpy_helper, TensorProto
import onnxruntime as ort
ort.disable_telemetry_events()
from safetensors.numpy import load_file
from tokenizers import Tokenizer

EXECUTION_CONFIG = 'ort1.23.2-all-cpu-u8s8-cased128-dense512-v1'


def digest(p):
    with p.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def session(path, threads):
    opts = ort.SessionOptions()
    opts.intra_op_num_threads = threads
    opts.inter_op_num_threads = 1
    opts.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
    return ort.InferenceSession(str(path), opts, providers=['CPUExecutionProvider'])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', default='private/tablet-test/oil-filter-tablet-reference.knowledge.json')
    parser.add_argument('--weights', default='models/local/distiluse-int8')
    parser.add_argument('--output', default='private/rag-stage/bundle')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    out = (root / args.output).resolve()
    if not out.is_relative_to(root / 'private'):
        raise ValueError('Source-derived output must stay under private/')
    out.mkdir(parents=True, exist_ok=True)
    weights = root / args.weights
    model_path = out / 'model.onnx'
    graph = onnx.load(str(weights / 'model_quantized.onnx'))
    dense = load_file(str(weights / 'dense.safetensors'))
    w = dense['linear.weight'].T
    b = dense['linear.bias']
    assert w.shape == (768, 512) and b.shape == (512,)
    graph.graph.initializer.extend([
        numpy_helper.from_array(w, 'rag_dense_w'), numpy_helper.from_array(b, 'rag_dense_b'),
        numpy_helper.from_array(np.array(1e-9, dtype=np.float32), 'rag_eps'),
    ])
    # Preserve the original INT8 encoder; append its documented mean pool + Dense/Tanh.
    graph.graph.node.extend([
        helper.make_node('Cast', ['attention_mask'], ['rag_mask'], to=TensorProto.FLOAT),
        helper.make_node('Unsqueeze', ['rag_mask'], ['rag_mask3'], axes=[2]),
        helper.make_node('Mul', ['last_hidden_state', 'rag_mask3'], ['rag_masked']),
        helper.make_node('ReduceSum', ['rag_masked'], ['rag_sum'], axes=[1], keepdims=0),
        helper.make_node('ReduceSum', ['rag_mask'], ['rag_count'], axes=[1], keepdims=1),
        helper.make_node('Div', ['rag_sum', 'rag_count'], ['rag_mean']),
        helper.make_node('MatMul', ['rag_mean', 'rag_dense_w'], ['rag_dense']),
        helper.make_node('Add', ['rag_dense', 'rag_dense_b'], ['rag_biased']),
        helper.make_node('Tanh', ['rag_biased'], ['rag_sentence']),
        helper.make_node('ReduceL2', ['rag_sentence'], ['rag_norm'], axes=[1], keepdims=1),
        helper.make_node('Max', ['rag_norm', 'rag_eps'], ['rag_safe_norm']),
        helper.make_node('Div', ['rag_sentence', 'rag_safe_norm'], ['embedding']),
    ])
    del graph.graph.output[:]
    graph.graph.output.append(helper.make_tensor_value_info('embedding', TensorProto.FLOAT, ['batch_size', 512]))
    onnx.checker.check_model(graph)
    onnx.save(graph, str(model_path))
    tokenizer = Tokenizer.from_file(str(weights / 'tokenizer.json'))
    tokenizer.enable_truncation(max_length=128)

    def feed(text):
        enc = tokenizer.encode(text)
        return {'input_ids': np.array([enc.ids], dtype=np.int64),
                'attention_mask': np.array([enc.attention_mask], dtype=np.int64)}

    encoder = session(weights / 'model_quantized.onnx', 2)
    merged = session(model_path, 2)
    probes = ['오일필터 교환 주기는 어떻게 됩니까?', '엔진 오일 필터 O-ring 점검',
              '일반 기준과 가혹 조건', '압력 20,000km / 12개월', '[CLS] 필터', '가\t나\n다', 'Aé 한글 中文',
              '오일필터 점검 ' * 80]
    max_error = 0.0
    for text in probes:
        inputs = feed(text)
        hidden = encoder.run(None, inputs)[0]
        mean = (hidden * inputs['attention_mask'][:, :, None]).sum(axis=1) / inputs['attention_mask'].sum(axis=1)[:, None]
        expected = np.tanh(mean @ w + b)
        expected /= np.linalg.norm(expected, axis=1, keepdims=True)
        actual = merged.run(None, inputs)[0]
        max_error = max(max_error, float(np.abs(expected - actual).max()))
    assert max_error < 1e-4, max_error
    del encoder
    source = json.loads((root / args.source).read_text(encoding='utf-8'))
    assert source['knowledge']['pending'] == []
    chunks = []
    def condition(e):
        policies, axes = set(), set()
        for template in source['knowledge']['templates']:
            if template['conceptId'] != e.get('conceptId'): continue
            for policy in ['normal', 'severe']:
                profile = template[policy]
                if profile['sourceRef'] == e['sourceRef']:
                    policies.add(policy)
                    if profile.get('km') is not None: axes.add('distance')
                    if profile.get('months') is not None: axes.add('period')
        return {'policies': sorted(policies), 'axes': sorted(axes), 'kind': 'cycle_reference' if policies else 'reference'}
    # Token offsets retain exact original text and source location. No forced symptom fields.
    untruncated = Tokenizer.from_file(str(weights / 'tokenizer.json'))
    untruncated.no_truncation()
    for e in source['evidence']:
        encoded = untruncated.encode(e['text'], add_special_tokens=False)
        for n, start in enumerate(range(0, len(encoded.ids), 96)):
            end = min(start + 112, len(encoded.ids))
            a, z = encoded.offsets[start][0], encoded.offsets[end - 1][1]
            text = e['text'][a:z]
            vector = merged.run(None, feed(text))[0][0]
            chunks.append({'id': f"{e['id']}-C{n:03}", 'evidenceId': e['id'],
                'conceptId': e['conceptId'], 'text': text, 'charStart': a, 'charEnd': z, 'condition': condition(e),
                'sourceRef': e['sourceRef'], 'vector': vector.tolist()})
            if end == len(encoded.ids):
                break
    index = {'version': 1, 'modelId': 'distiluse-int8-v1', 'dimension': 512,
             'modelSha256': digest(model_path), 'executionConfig': EXECUTION_CONFIG,
             'sourceEvidence': source['evidence'], 'chunks': chunks}
    (out / 'index.json').write_text(json.dumps(index, ensure_ascii=False), encoding='utf-8')
    (out / 'knowledge.json').write_text(json.dumps(source, ensure_ascii=False), encoding='utf-8')
    (out / 'vocab.txt').write_bytes((weights / 'vocab.txt').read_bytes())
    (out / 'LICENSE.txt').write_bytes((weights / 'LICENSE.txt').read_bytes())
    probes += ['오일필터 교환 주기', '오일 필터를 분리하는 절차', '가혹 조건에서 몇 개월마다 교환하나요',
               '일반 조건에서 주행거리를 기준으로 교환하는 근거', '일반과 가혹의 거리 기간 기준을 비교', '오일필터 교환 기간은?']
    parity = [{'text': t, 'ids': feed(t)['input_ids'][0].tolist(),
               'embedding': merged.run(None, feed(t))[0][0].tolist()} for t in probes]
    (out.parent / 'parity-probes.json').write_text(json.dumps(parity, ensure_ascii=False), encoding='utf-8')
    manifest = {'version': 1, 'modelId': 'distiluse-int8-v1', 'dimension': 512, 'maxTokens': 128,
                'minAndroidApi': 24, 'runtime': 'onnxruntime-1.23.2-cpu',
                'quantization': 'INT8 U8S8 encoder + FP32 sentence head', 'license': 'Apache-2.0',
                'executionConfig': EXECUTION_CONFIG,
                'sourceModel': 'sentence-transformers/distiluse-base-multilingual-cased-v2',
                'sourceRevision': 'bfe45d0732ca50787611c0fe107ba278c7f3f889',
                'encoderRevision': 'cad454171d918d9873a2701ba245054b6c1760dd',
                'files': {p.name: {'bytes': p.stat().st_size, 'sha256': digest(p)} for p in out.iterdir() if p.name != 'manifest.json'}}
    (out / 'manifest.json').write_text(json.dumps(manifest, indent=2), encoding='utf-8')
    with zipfile.ZipFile(out.parent / 'oil-filter-int8.mrag', 'w', zipfile.ZIP_DEFLATED) as archive:
        for p in out.iterdir(): archive.write(p, p.name)
    report = {'platform': 'pc-cpu', 'physicalDevice': False, 'runtime': ort.__version__,
              'chunks': len(chunks), 'evidence': len(source['evidence']), 'pending': 0,
              'executionConfig': EXECUTION_CONFIG,
              'sentenceHeadMaxAbsError': max_error, 'modelBytes': model_path.stat().st_size,
              'modelSha256': digest(model_path), 'benchmark': []}
    for threads in [2, 4]:
        del merged
        started = time.perf_counter()
        merged = session(model_path, threads)
        load_ms = (time.perf_counter() - started) * 1000
        for _ in range(3): merged.run(None, feed(probes[0]))
        latencies = []
        for n in range(20):
            started = time.perf_counter()
            merged.run(None, feed(probes[n % len(probes)]))
            latencies.append((time.perf_counter() - started) * 1000)
        report['benchmark'].append({'threads': threads, 'interOpThreads': 1, 'warmup': 3, 'samples': 20,
            'inputTokens': [len(feed(probes[n % len(probes)])['input_ids'][0]) for n in range(20)],
            'loadMs': load_ms, 'p50Ms': float(np.percentile(latencies, 50)), 'p95Ms': float(np.percentile(latencies, 95))})
    (out.parent / 'pc-result.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(json.dumps(report))

if __name__ == '__main__': main()
