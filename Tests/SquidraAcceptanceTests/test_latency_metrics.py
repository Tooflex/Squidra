import math
import unittest
from latency_metrics import summarize,evaluate
import copy


class LatencyMetricsTests(unittest.TestCase):
    def test_known_linear_quantiles_and_even_median(self):
        result=summarize(list(range(30,0,-1)))
        self.assertEqual(result['p50'],15.5)
        self.assertAlmostEqual(result['p95'],28.55)
        self.assertEqual(result['median'],15.5)
        self.assertEqual(result['count'],30)

    def test_single_sample_and_equal_samples(self):
        self.assertEqual(summarize([7],1)['p95'],7)
        self.assertEqual(summarize([0]*30)['median'],0)

    def test_no_outlier_removal(self):
        self.assertEqual(summarize([1]*28+[100,1000])['maximum'],1000)
        self.assertGreater(summarize([1]*28+[100,1000])['p95'],1)

    def test_incomplete_nonfinite_negative_and_boolean_rejected(self):
        for values in [[],[1]*29,[1]*31,[1]*29+[math.nan],[1]*29+[math.inf],[1]*29+[-1],[1]*29+[True]]:
            with self.assertRaises(ValueError):summarize(values)

    def test_profile_requires_successful_unique_complete_samples(self):
        raw={'mode':'offline-scripted-latency','measuredCount':30,'warmupCount':3,'concurrency':1,'realModelExecuted':False,'providerCalls':0}
        for name,calls,reads,identity in [('runtime',2,1,'runID'),('toolFreeModelPort',1,0,'requestID')]:
            raw[name]=[{'milliseconds':float(i),'warmup':i<3,'modelCalls':calls,'worldReads':reads,identity:str(i),'state':'COMPLETED'} for i in range(33)]
        self.assertEqual(evaluate(raw)['runtime']['count'],30)
        for key,value in [('warmup',True),('modelCalls',1),('worldReads',0),('state','FAILED'),('runID','0')]:
            bad=copy.deepcopy(raw);bad['runtime'][4][key]=value
            with self.assertRaises(ValueError):evaluate(bad)
        bad=copy.deepcopy(raw);bad['runtime'][0]['milliseconds']=math.inf
        with self.assertRaises(ValueError):evaluate(bad)
        bad=copy.deepcopy(raw);bad['realModelExecuted']=True
        with self.assertRaises(ValueError):evaluate(bad)


if __name__=='__main__':
    run=unittest.main(exit=False)
    if not run.result.wasSuccessful():raise SystemExit(1)
    print('SQUIDRA_TEST_PASS:latency_metric_contracts')
