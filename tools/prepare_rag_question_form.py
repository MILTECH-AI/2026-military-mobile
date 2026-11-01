"""Build an offline, unanswered 25-question form. Source-derived output: private only."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'private/retrieval-stage/evaluation'

def main():
    OUT.mkdir(parents=True, exist_ok=True)
    bundle = json.loads((ROOT / 'private/retrieval-stage/bundle/knowledge.json').read_text(encoding='utf-8'))
    groups = [('일반·거리', 3), ('일반·기간', 3), ('가혹·거리', 3), ('가혹·기간', 3),
              ('일반·가혹 비교', 3), ('부대 미선택·질문 조건 충돌·모호한 조건', 4), ('교환 절차·주의사항', 4), ('범위 밖·근거 없음', 2)]
    rows = []
    for category, count in groups:
        for _ in range(count):
            rows.append({'id': f'Q{len(rows)+1:02}', 'category': category, 'question': '',
                         'selectedUnitPolicy': 'unselected', 'questionPolicy': '', 'axes': [],
                         'expectedBehavior': '', 'goldEvidence': [], 'mustRankFirst': [],
                         'reviewedAgainstOriginal': False, 'reviewNote': ''})
    data = {'version': 1, 'status': 'unfilled_template', 'scope': '오일필터',
            'purpose': '팀이 질문과 원문 정답 위치를 작성하는 검색 평가 양식. 호환성 입력과 별개.',
            'sourceCatalog': [{'evidenceId': e['id'], 'sourceRef': e['sourceRef']} for e in bundle['evidence']], 'questions': rows}
    (OUT / 'questions-template.json').write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding='utf-8')
    html = '''<!doctype html><html lang="ko"><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'none'; img-src 'none'; form-action 'none'">
<title>오일필터 검색 평가 · 팀 작성용 25문항</title>
<style>body{max-width:1000px;margin:30px auto;padding:0 20px;font:16px/1.6 sans-serif;color:#152132;background:#f5f7fa}article,aside{background:white;border:1px solid #ccd4df;padding:20px;margin:20px 0;border-radius:8px}label{display:block;margin:8px 0}textarea,input,select{font:inherit;box-sizing:border-box;max-width:100%;padding:8px}textarea{width:100%;min-height:90px}h2{font-size:20px}button{padding:10px 16px;font:inherit}pre{white-space:pre-wrap;overflow-wrap:anywhere}#result{height:300px}</style>
<h1>오일필터 검색 평가 · 팀 작성용 25문항</h1>
<p>질문과 정답은 모두 비어 있습니다. 원문을 확인한 팀원이 작성하세요. 실제 차량 식별자를 입력하지 마세요. 인터넷 연결·외부 전송·자동 저장은 없습니다. 창을 닫으면 입력이 사라집니다.</p>
<p>교환 수치의 기대 결과는 등록 규칙과 부대 선택으로 판정합니다. RAG의 정답은 원문 근거 위치입니다. 부대 선택과 질문 조건이 충돌하는 문항은 검색 기대와 적용 수치 기대를 구분해 검토 메모에 적으세요.</p>
<aside><h2>원문 위치 참고 목록</h2><p>아래는 등록 근거의 위치 목록이며 문항별 정답표가 아닙니다. 원문 PDF를 대조하고 허용 근거를 직접 정하세요. 같은 쪽의 여러 조각을 모두 정답으로 인정할지 적으세요.</p><pre id="catalog"></pre></aside>
<label>저장했던 JSON 불러오기 <input type="file" id="load" accept=".json"></label>
<main id="rows"></main><button id="export">입력 검사 후 저장할 JSON 표시</button>
<p id="message"></p><label>아래 내용을 로컬 <b>private/retrieval-stage/evaluation/questions-filled.json</b>에 저장하세요. 외부 문서·클라우드에 붙여넣지 마세요.<textarea id="result" readonly></textarea></label>
<script>const seed=__DATA__;let data=structuredClone(seed);
const el=(tag,text)=>{const n=document.createElement(tag);if(text)n.textContent=text;return n};
function render(){document.querySelector('#catalog').textContent=JSON.stringify(data.sourceCatalog,null,2);const root=document.querySelector('#rows');root.replaceChildren();
for(const q of data.questions){const a=el('article');a.append(el('h2',q.id+' · '+q.category));
function field(title,key,type='text'){const l=el('label',title);const n=el(type==='area'?'textarea':'input');n.value=q[key];n.oninput=()=>q[key]=n.value;l.append(n);a.append(l)}
field('질문 (팀 작성)','question','area');
function select(title,key,options){const l=el('label',title+' '),n=el('select');for(const [value,label] of options){const o=el('option',label);o.value=value;n.append(o)}n.value=q[key];n.onchange=()=>q[key]=n.value;l.append(n);a.append(l)}
select('부대 기준', 'selectedUnitPolicy',[['unselected','미선택'],['normal','일반'],['severe','가혹']]);
select('질문에 명시된 기준','questionPolicy',[['','검토 전'],['none','명시 없음'],['normal','일반'],['severe','가혹'],['both','둘 다'],['ambiguous','모호함']]);
select('기대 동작','expectedBehavior',[['','검토 전'],['rule_value','규칙·부대 설정의 수치 + 원문'],['evidence_reference','원문 근거'],['clarification','조건 확인 요청'],['no_evidence','해당 근거 없음']]);
for(const axis of ['distance','period']){const l=el('label',axis==='distance'?'거리 조건':'기간 조건'),n=el('input');n.type='checkbox';n.checked=q.axes.includes(axis);n.onchange=()=>q.axes=n.checked?[...q.axes.filter(x=>x!==axis),axis]:q.axes.filter(x=>x!==axis);l.prepend(n);a.append(l)}
const l=el('label','정답 근거 배열(JSON): evidenceId, file, pdfPage, printedPage, section, chunkIds. 복수 근거 허용. 근거 없음이면 []');const g=el('textarea');g.value=JSON.stringify(q.goldEvidence,null,2);g.oninput=()=>{try{const value=JSON.parse(g.value);if(!Array.isArray(value))throw Error();q.goldEvidence=value;g.setCustomValidity('')}catch{g.setCustomValidity('JSON 배열을 입력하세요')}};a.append(l,g);
field('반드시 1위여야 하는 근거 ID (쉼표 구분, 복수 허용)', '_first');a.lastChild.lastChild.value=q.mustRankFirst.join(',');a.lastChild.lastChild.oninput=e=>q.mustRankFirst=e.target.value.split(',').map(s=>s.trim()).filter(Boolean);
field('검토 메모: 적용 수치 기대 / 모호성 / 복수 정답 이유','reviewNote','area');const c=el('input');c.type='checkbox';c.checked=q.reviewedAgainstOriginal;c.onchange=()=>q.reviewedAgainstOriginal=c.checked;const cl=el('label','원문 PDF를 확인해 정답 위치를 검토했음');cl.prepend(c);a.append(cl);root.append(a)}}
document.querySelector('#export').onclick=()=>{const errors=[];for(const q of data.questions){delete q._first;if(!q.reviewedAgainstOriginal)continue;if(!q.question.trim()||!q.questionPolicy||!q.expectedBehavior)errors.push(q.id+': 질문·조건·기대 동작 필요');if(!Array.isArray(q.goldEvidence)|| (q.expectedBehavior!=='no_evidence'&&q.goldEvidence.length===0))errors.push(q.id+': 정답 근거 필요');for(const g of q.goldEvidence){if(!g.evidenceId||!g.file||!Number.isInteger(g.pdfPage)||g.pdfPage<1)errors.push(q.id+': 근거 ID·파일·PDF쪽 필요')}const ids=q.goldEvidence.map(g=>g.evidenceId);if(q.mustRankFirst.some(id=>!ids.includes(id)))errors.push(q.id+': 1위 근거가 정답 근거 목록에 없음')}for(const t of document.querySelectorAll('textarea'))if(!t.checkValidity())errors.push('JSON 형식 오류');document.querySelector('#message').textContent=errors.length?errors.join(' / '):'검사 완료. 미검토 문항은 평가에서 제외하세요.';data.status='team_draft';document.querySelector('#result').value=JSON.stringify(data,null,2)};
document.querySelector('#load').onchange=async e=>{try{const d=JSON.parse(await e.target.files[0].text());if(d.version!==1||d.questions.length!==25||d.questions.some(q=>!Array.isArray(q.goldEvidence)||!Array.isArray(q.axes)))throw Error();data=d;render()}catch{document.querySelector('#message').textContent='양식과 맞는 JSON인지 확인하세요.'}};render();</script></html>'''
    # Escaping '<' prevents source metadata from becoming a script terminator.
    (OUT / 'questions-form.html').write_text(html.replace('__DATA__', json.dumps(data, ensure_ascii=False).replace('<', '\\u003c')), encoding='utf-8')
    (OUT / 'README.txt').write_text('''질문 25개와 정답은 미작성 상태입니다. HTML을 로컬 브라우저에서 열어 작성하거나 JSON을 직접 편집합니다.
정답 근거 예시 형식(가상): {"evidenceId":"FAKE-E","file":"가상.pdf","pdfPage":1,"printedPage":"1-1","section":"가상 절","chunkIds":[]}
원문 대조 전에는 reviewedAgainstOriginal을 true로 바꾸지 않습니다. 질문을 작성한 후 검색 결과를 보기 전에 정답 위치를 고정하세요.
질문·부대 선택·기준시각·모델/색인 해시·top-k·실행 플랫폼을 함께 기록합니다.
평가 예정: 검토 완료 문항만 대상으로 근거 Recall@1/3/5, MRR, 필수 1위 충족 건수와 조건 혼동 건수를 원시 개수와 함께 보고합니다.
정답 복수 허용 여부를 고정하고 근거 없음 문항은 별도 집계합니다. 25개 양식만으로 측정값이나 일반화 성능을 주장하지 않습니다.
독립 라벨링·일치도 평가는 진행하지 않습니다. 기존 보관본은 건드리지 않습니다. 결과는 private 내부에만 저장합니다.
''', encoding='utf-8')
    print('25 blank questions; private/retrieval-stage/evaluation')

if __name__ == '__main__':
    main()
