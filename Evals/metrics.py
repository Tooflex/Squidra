"""Strict component metrics. No missing prediction is counted as a negative."""
THRESHOLDS = {'temporal_accuracy': 0.90, 'spatial_accuracy': 0.85, 'movement_f1': 0.85}


def score(cases, predictions):
    if not cases or not isinstance(cases, list) or not isinstance(predictions, list):
        raise ValueError('Nonempty cases and prediction list required')
    truth = {}
    for case in cases:
        if (not isinstance(case, dict) or not isinstance(case.get('id'), str) or not case['id']
                or case['id'] in truth or case.get('kind') not in ('temporal', 'spatial', 'movement')
                or type(case.get('expected')) is not bool):
            raise ValueError('Invalid or duplicate case')
        truth[case['id']] = case
    actual = {}
    for item in predictions:
        if (not isinstance(item, dict) or set(item) != {'id', 'prediction'}
                or not isinstance(item['id'], str) or item['id'] in actual
                or type(item['prediction']) is not bool):
            raise ValueError('Invalid or duplicate prediction')
        actual[item['id']] = item['prediction']
    if set(actual) != set(truth):
        raise ValueError('Missing or unexpected prediction IDs')
    result = {}
    for kind in ('temporal', 'spatial'):
        rows = [c for c in cases if c['kind'] == kind]
        if not rows:
            raise ValueError('Empty accuracy denominator')
        correct = sum(actual[c['id']] == c['expected'] for c in rows)
        result[kind] = {'correct': correct, 'total': len(rows), 'accuracy': correct / len(rows)}
    rows = [c for c in cases if c['kind'] == 'movement']
    if not rows or not any(c['expected'] for c in rows) or all(c['expected'] for c in rows):
        raise ValueError('Movement set must contain positive and negative cases')
    tp = sum(actual[c['id']] and c['expected'] for c in rows)
    fp = sum(actual[c['id']] and not c['expected'] for c in rows)
    fn = sum(not actual[c['id']] and c['expected'] for c in rows)
    tn = len(rows) - tp - fp - fn
    result['movement'] = {'total': len(rows), 'tp': tp, 'fp': fp, 'fn': fn, 'tn': tn,
                          'precision_denominator': tp + fp, 'recall_denominator': tp + fn,
                          'f1_denominator': 2 * tp + fp + fn,
                          'precision': tp / (tp + fp) if tp + fp else None,
                          'recall': tp / (tp + fn), 'f1': 2 * tp / (2 * tp + fp + fn)}
    result['thresholds'] = dict(THRESHOLDS)
    result['passed'] = (result['temporal']['accuracy'] >= THRESHOLDS['temporal_accuracy']
                        and result['spatial']['accuracy'] >= THRESHOLDS['spatial_accuracy']
                        and result['movement']['f1'] >= THRESHOLDS['movement_f1'])
    return result
