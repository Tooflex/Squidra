import copy
import unittest
from Evals.metrics import score


class MetricTests(unittest.TestCase):
    def setUp(self):
        self.cases = [dict(id=str(i), kind=k, expected=v) for i, (k, v) in enumerate([
            ('temporal', True), ('temporal', False), ('spatial', True), ('spatial', False),
            ('movement', True), ('movement', True), ('movement', False), ('movement', False)])]
        self.predictions = [dict(id=c['id'], prediction=c['expected']) for c in self.cases]

    def test_perfect_denominators(self):
        result = score(self.cases, self.predictions)
        self.assertEqual(result['temporal'], dict(correct=2, total=2, accuracy=1))
        self.assertEqual(result['movement']['tp'], 2)
        self.assertEqual(result['movement']['tn'], 2)
        self.assertEqual(result['movement']['f1_denominator'], 4)
        self.assertTrue(result['passed'])

    def test_confusion_counts_and_threshold_failure(self):
        self.predictions[4]['prediction'] = False
        self.predictions[6]['prediction'] = True
        result = score(self.cases, self.predictions)
        self.assertEqual([result['movement'][x] for x in ['tp', 'fp', 'fn', 'tn']], [1, 1, 1, 1])
        self.assertEqual(result['movement']['f1'], .5)
        self.assertFalse(result['passed'])

    def test_no_change_baseline_does_not_get_perfect_f1(self):
        result = score(self.cases, [dict(id=c['id'], prediction=False) for c in self.cases])
        self.assertEqual(result['movement']['f1'], 0)
        self.assertIsNone(result['movement']['precision'])
        self.assertEqual(result['movement']['fn'], 2)

    def test_missing_extra_duplicate_predictions_fail(self):
        for predictions in [self.predictions[:-1], self.predictions + [self.predictions[0]],
                            self.predictions + [dict(id='unexpected', prediction=False)]]:
            with self.assertRaises(ValueError): score(self.cases, predictions)

    def test_nonboolean_and_unknown_fields_fail(self):
        for value in [0, 1, 'false', None, float('nan'), float('inf')]:
            predictions = copy.deepcopy(self.predictions)
            predictions[0]['prediction'] = value
            with self.assertRaises(ValueError): score(self.cases, predictions)
        self.predictions[0]['unused'] = True
        with self.assertRaises(ValueError): score(self.cases, self.predictions)

    def test_empty_categories_and_duplicate_labels_fail(self):
        for cases in [[], self.cases + [self.cases[0]], [c for c in self.cases if c['kind'] != 'spatial'],
                      [c for c in self.cases if c['kind'] != 'movement' or not c['expected']]]:
            predictions = [dict(id=c['id'], prediction=c['expected']) for c in cases]
            with self.assertRaises(ValueError): score(cases, predictions)

    def test_input_order_does_not_change_metrics(self):
        self.assertEqual(score(self.cases, self.predictions), score(list(reversed(self.cases)), list(reversed(self.predictions))))
