"""Local-only provisional system classifier. No network, verified-history claim or assets output."""
import os
os.environ.setdefault('OPENBLAS_NUM_THREADS','2')
import argparse
import collections
import hashlib
import json
import re
import zipfile
from pathlib import Path
from pilot_groups import build_groups, vehicle_key
import numpy as np
import onnx
from onnx import TensorProto,helper,numpy_helper

ROOT=Path(__file__).resolve().parents[1]
DIM=4096
CONFIG='hash-char-binary-fnv1a32-v1'

def normalize(text):
    return re.sub(' +',' ',re.sub('[^a-z가-힣ㄱ-ㅎㅏ-ㅣ ]',' ',text.replace(r'\r\n',' ').lower())).strip()

def feature_ids(text):
    text='^'+normalize(text)+'$'
    ids=set()
    for n in [2,3,4]:
        for at in range(len(text)-n+1):
            h=2166136261
            for byte in text[at:at+n].encode('utf-8'): h=((h^byte)*16777619)&0xffffffff
            ids.add(h%DIM)
    return sorted(ids)

def features(text):
    a=np.zeros(DIM,dtype=np.float32)
    if normalize(text): a[feature_ids(text)]=1
    return a

def fit(x,y,classes):
    counts=np.stack([x[y==k].sum(axis=0,dtype=np.float64)+1 for k in range(classes)])
    prior=np.array([(y==k).sum() for k in range(classes)],dtype=np.float64)
    assert (prior>0).all()
    return np.log(counts/counts.sum(axis=1,keepdims=True)).astype(np.float32),np.log(prior/prior.sum()).astype(np.float32)

def scores(x,w,b):
    z=x@w.T+b; z-=z.max(axis=-1,keepdims=True); z=np.exp(z)
    return z/z.sum(axis=-1,keepdims=True)

def metrics(y,p,labels):
    m=np.zeros((len(labels),len(labels)),dtype=int)
    for a,b in zip(y,p):m[a,b]+=1
    f=[]
    for k in range(len(labels)):
        tp=int(m[k,k]);precision=tp/max(1,int(m[:,k].sum()));recall=tp/max(1,int(m[k].sum()))
        f.append(2*precision*recall/max(1e-12,precision+recall))
    return {'agreementWithDraftLabels':float((y==p).mean()),'macroF1AgainstDraftLabels':float(np.mean(f)),'confusion':m.tolist(),'labelOrder':labels,'samples':len(y)}

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--output',default='private/system-pilot');args=parser.parse_args()
    out=(ROOT/args.output).resolve()
    if not out.is_relative_to((ROOT/'private').resolve()):raise ValueError('Learned artifacts and source-derived outputs must stay under private/')
    out.mkdir(parents=True,exist_ok=True)
    read=lambda name:json.loads((ROOT/name).read_text(encoding='utf-8-sig'))
    rows=read('private/step2/maintenance-rows.json');draft=read('private/labeling-stage/draft.json');keys=read('private/labeling-stage/private-source-key.json');taxonomy=read('private/labeling-stage/taxonomy.json')
    by_id={d['id']:d for d in draft}; vehicles=sorted({r['vehicle'].strip() for r in rows if r['vehicle'].strip()},key=len,reverse=True)
    eligible=[];excluded=[]
    for key in keys:
        d=by_id[key['id']];r=rows[key['sourceIndex']-1]
        assert d['pdfPage']==r['page']==key['pdfPage'] and d['rowOnPage']==r['rowOnPage']==key['rowOnPage']
        text=r['description']
        for vehicle in vehicles:text=text.replace(vehicle,' ')
        text=normalize(text)
        item={'id':d['id'],'text':text,'label':d['primarySystem'],'concepts':d['concepts'],'vehicle':r['vehicle'],'sourceIndex':key['sourceIndex'],'sourcePdfPage':r['page'],'sourceRow':r['rowOnPage']}
        if d['needsReview'] or d['primarySystem'] in ['MULTI','UNKNOWN'] or not text:excluded.append(item)
        else:eligible.append(item)
    labels=sorted({r['label'] for r in eligible});names=[taxonomy[k][0] for k in labels]
    x=np.stack([features(r['text']) for r in eligible]);y=np.array([labels.index(r['label']) for r in eligible])
    group_ids,near_pairs,grouping=build_groups(eligible)
    grouping['sourceVehicleGroups']=len({vehicle_key(r['vehicle']) for r in eligible if vehicle_key(r['vehicle'])})
    def find(i):return group_ids[i]
    groups=collections.defaultdict(list)
    for i in range(len(eligible)):groups[find(i)].append(i)
    rng=np.random.default_rng(20261031);g=list(groups.values());rng.shuffle(g);g.sort(key=len,reverse=True)
    fold_counts=np.zeros((3,len(labels)));fold_sizes=np.zeros(3);folds=np.full(len(eligible),-1);total=np.bincount(y,minlength=len(labels))
    for group in g:
        count=np.bincount(y[group],minlength=len(labels))
        costs=[float((((fold_counts[f]+count)/total)**2-(fold_counts[f]/total)**2).sum()+.05*(fold_sizes[f]/len(y))**2) for f in range(3)]
        f=min(range(3),key=lambda f:(costs[f],fold_sizes[f],f));folds[group]=f;fold_counts[f]+=count;fold_sizes[f]+=len(group)
    oof=np.zeros((len(y),len(labels)),dtype=np.float32);baseline=np.zeros(len(y),dtype=int);fold_reports=[]
    for f in range(3):
        train=folds!=f;test=~train;w,b=fit(x[train],y[train],len(labels));p=scores(x[test],w,b);oof[test]=p;baseline[test]=int(np.bincount(y[train],minlength=len(labels)).argmax())
        train_v={vehicle_key(eligible[i]['vehicle']) for i in np.flatnonzero(train)}-{''};test_v={vehicle_key(eligible[i]['vehicle']) for i in np.flatnonzero(test)}-{''}
        cross_near=sum(int(folds[a]!=folds[b]) for a,b in near_pairs)
        disjoint=not bool({find(i) for i in np.flatnonzero(train)}&{find(i) for i in np.flatnonzero(test)})
        assert disjoint and not (train_v&test_v) and cross_near==0
        fold_reports.append({'fold':f,'train':int(train.sum()),'test':int(test.sum()),'groupsDisjoint':disjoint,'vehicleOverlapCount':len(train_v&test_v),'crossFoldSimilarPairCount':cross_near,'trainClassSupport':np.bincount(y[train],minlength=len(labels)).tolist(),'classSupport':np.bincount(y[test],minlength=len(labels)).tolist()})
    w,b=fit(x,y,len(labels));prediction=scores(x,w,b)
    model=helper.make_model(helper.make_graph([
        helper.make_node('MatMul',['features','weights'],['dot']),helper.make_node('Add',['dot','bias'],['logits']),helper.make_node('Softmax',['logits'],['scores'],axis=1)],
        'system-draft-pilot',[helper.make_tensor_value_info('features',TensorProto.FLOAT,[1,DIM])],[helper.make_tensor_value_info('scores',TensorProto.FLOAT,[1,len(labels)])],
        [numpy_helper.from_array(w.T.copy(),'weights'),numpy_helper.from_array(b,'bias')]),opset_imports=[helper.make_opsetid('',13)])
    model.ir_version=8;onnx.checker.check_model(model)
    bundle=out/'bundle';bundle.mkdir(exist_ok=True);onnx.save(model,bundle/'model.onnx')
    metadata={'version':1,'modelId':'maintenance-system-pilot-v1','featureConfig':CONFIG,'dimension':DIM,'maxChars':2000,'labels':names,'labelIds':labels,
              'seenFeatureIds':np.flatnonzero(x.sum(axis=0)>0).tolist(),'sourceStatus':'authorship_unconfirmed','labelStatus':'single_ai_draft_not_human_reviewed','use':'suggestion_only',
              'trainingSamples':len(y),'excludedNeedsReview':len(excluded),'algorithm':'binary hashed character 2-4grams + multinomial naive Bayes, alpha=1',
              'moduleName':'규칙 기반 잔여 정비거리 + 정비기록 분류',
              'predictionTarget':'maintenance system from description, not next-month vehicle failure probability'}
    (bundle/'model.json').write_text(json.dumps(metadata,ensure_ascii=False),encoding='utf-8')
    digest=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
    manifest={'version':1,'modelId':metadata['modelId'],'minAndroidApi':24,'files':{p.name:{'bytes':p.stat().st_size,'sha256':digest(p)} for p in bundle.iterdir() if p.name!='manifest.json'}}
    (bundle/'manifest.json').write_text(json.dumps(manifest,indent=2),encoding='utf-8')
    with zipfile.ZipFile(out/'system-pilot.msystem','w',zipfile.ZIP_DEFLATED) as z:
        for name in ['model.onnx','model.json','manifest.json']:z.write(bundle/name,name)
    import onnxruntime as ort
    options=ort.SessionOptions();options.intra_op_num_threads=2;options.inter_op_num_threads=1
    session=ort.InferenceSession(str(bundle/'model.onnx'),options,providers=['CPUExecutionProvider'])
    probes=[]
    probe_indices=[i for label in labels for i in [j for j,r in enumerate(eligible) if r['label']==label][:3]]
    for n,i in enumerate(probe_indices):
        item=eligible[i]
        actual=session.run(None,{'features':features(item['text'])[None]})[0][0]
        assert np.max(np.abs(actual-prediction[i]))<1e-4
        probes.append({'id':f'PILOT-PROBE-{n+1:03}','text':item['text'],'featureIds':feature_ids(item['text']),'pcScores':actual.tolist()})
    (out/'parity-probes.json').write_text(json.dumps(probes,ensure_ascii=False),encoding='utf-8')
    (out/'split-audit.json').write_text(json.dumps([{'id':r['id'],'sourceIndex':r['sourceIndex'],'fold':int(folds[i]),'group':find(i),'label':r['label'],'sanitizedText':r['text']} for i,r in enumerate(eligible)],ensure_ascii=False,indent=2),encoding='utf-8')
    report={'moduleName':'규칙 기반 잔여 정비거리 + 정비기록 분류','grouping':grouping,'sourceRows':len(rows),'eligibleDraftRows':len(eligible),'excludedAmbiguousDraftRows':len(excluded),'classes':len(labels),'groups':len(g),'folds':fold_reports,
            'oof':metrics(y,oof.argmax(axis=1),names),'majorityBaseline':metrics(y,baseline,names),'modelBytes':(bundle/'model.onnx').stat().st_size,
            'sourceStatus':metadata['sourceStatus'],'labelStatus':metadata['labelStatus'],'humanReviewed':False,'independentRealWorldAccuracyMeasured':False,
            'sourceInputHashes':{p:digest(ROOT/p) for p in ['private/step2/maintenance-rows.json','private/labeling-stage/draft.json','private/labeling-stage/private-source-key.json']},
            'inputFields':['description only; known vehicle values/digits/punctuation removed'],'excludedInputFields':['vehicle','date','price','part','source location','draft label text'],
            'limits':['Single draft labels, not verified truth','Provenance of original records unconfirmed','Grouped internal validation only; no external validation','Concept-string grouping cannot guarantee all synonyms grouped','Scores not calibrated probabilities; suggestion only']}
    (out/'training-report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps({k:report[k] for k in ['sourceRows','eligibleDraftRows','excludedAmbiguousDraftRows','classes','groups','modelBytes']}))

if __name__=='__main__':main()

