"""Label-free connected components for source vehicle and text leakage control."""
import difflib
import re


def vehicle_key(value):
    return re.sub(r'[\s-]+', '', value).upper()


def text_key(value):
    return re.sub(r'\s+', '', value)


def similar(a, b):
    a, b = text_key(a), text_key(b)
    if not a or not b:
        return False
    if a == b:
        return True
    grams = lambda s: {s[i:i+3] for i in range(len(s)-2)}
    x, y = grams(a), grams(b)
    jaccard = len(x & y) / len(x | y) if x | y else 0
    return (difflib.SequenceMatcher(None, a, b, autojunk=False).ratio() >= .70
            or jaccard >= .50)


def build_groups(rows):
    parent = list(range(len(rows)))

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    def union(a, b):
        parent[find(a)] = find(b)

    seen = {}
    vehicle_edges = concept_edges = 0
    for i, row in enumerate(rows):
        vehicle = vehicle_key(row['vehicle'])
        tokens = [('text', text_key(row['text']))]
        if vehicle:
            tokens.append(('vehicle', vehicle))
        tokens += [('concept', text_key(c)) for c in row['concepts'] if text_key(c)]
        for token in tokens:
            if token in seen:
                union(i, seen[token])
                vehicle_edges += token[0] == 'vehicle'
                concept_edges += token[0] == 'concept'
            else:
                seen[token] = i
    near_pairs = []
    for i in range(len(rows)):
        for j in range(i+1, len(rows)):
            if similar(rows[i]['text'], rows[j]['text']):
                near_pairs.append((i, j))
                union(i, j)
    groups = [find(i) for i in range(len(rows))]
    return groups, near_pairs, {
        'method': 'connected components: canonical vehicle OR exact text OR shared concept OR lexical near-duplicate',
        'similarityRule': 'whitespace removed; SequenceMatcher(autojunk=False)>=0.70 OR character-trigram Jaccard>=0.50',
        'thresholdMeaning': 'fixed leakage-control heuristic, not validated semantic equivalence or a tuned classification threshold',
        'vehicleKeyRule': 'remove whitespace/hyphens, uppercase; source ID identity itself unverified',
        'missingVehicleRows': sum(not vehicle_key(r['vehicle']) for r in rows),
        'vehicleLinkEdges': vehicle_edges, 'conceptLinkEdges': concept_edges,
        'similarTextPairs': len(near_pairs),
    }
