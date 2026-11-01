"""Public model-zoo black input and PyTorch example. Never reads military images."""
import hashlib
import json
import tarfile
import time
from pathlib import Path
import numpy as np
import onnx
import onnxruntime as ort
from onnx import numpy_helper
from PIL import Image

root = Path(__file__).resolve().parents[1]
model = root / 'models/local/ssd-mobilenet'
out = root / 'private/vision-stage'
out.mkdir(parents=True, exist_ok=True)
with tarfile.open(model / 'test-model.tar.gz') as archive:
    member = next(m for m in archive.getmembers() if m.name.endswith('input_0.pb'))
    tensor = onnx.TensorProto()
    tensor.ParseFromString(archive.extractfile(member).read())
    original = numpy_helper.to_array(tensor)
    Image.fromarray(original[0]).save(model / 'public-test-input.png')
    assert original.dtype == np.uint8

results=[]
for threads in [2,4]:
    options=ort.SessionOptions(); options.intra_op_num_threads=threads; options.inter_op_num_threads=1
    start=time.perf_counter()
    session=ort.InferenceSession(str(model/'model.onnx'),options,providers=['CPUExecutionProvider'])
    load=(time.perf_counter()-start)*1000
    for name in ['public-test-input.png','public-dog.jpg']:
        image=Image.open(model/name).convert('RGB')
        # Android uses the same fixed 300x300 nearest-neighbour fixture (PNG).
        image=image.resize((300,300),Image.Resampling.NEAREST)
        fixture=model/(Path(name).stem+'-300.png')
        image.save(fixture)
        pixels=np.array(image)[None]
        values=session.run(None,{'inputs':pixels})
        pred=dict(zip([x.name for x in session.get_outputs()],values))
        hits=[]
        for i in range(int(pred['num_detections'][0])):
            score=float(pred['detection_scores'][0,i])
            if score>=.5: hits.append({'classId':int(pred['detection_classes'][0,i]),'score':score,'box':pred['detection_boxes'][0,i].tolist()})
        times=[]
        for _ in range(5):
            start=time.perf_counter(); session.run(None,{'inputs':pixels}); times.append((time.perf_counter()-start)*1000)
        results.append({'threads':threads,'input':fixture.name,'sha256':hashlib.sha256(fixture.read_bytes()).hexdigest(),'loadMs':load,'warmup':1,'samples':5,'p50Ms':float(np.percentile(times,50)),'p95Ms':float(np.percentile(times,95)),'detections':hits})
report={'platform':'pc-cpu','physicalDevice':False,'runtime':ort.__version__,'modelSha256':hashlib.sha256((model/'model.onnx').read_bytes()).hexdigest(),
        'purpose':'Public model execution path only; no Rexton part detection accuracy claim','benchmark':results}
(out/'pc-result.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
print(json.dumps({'platform':'pc-cpu','runs':len(results),'detections':[len(r['detections']) for r in results]}))
