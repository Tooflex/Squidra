"""Linear-interpolated sample quantiles; no SLA or outlier removal."""
import math


def summarize(values, expected_count=30):
    if (type(expected_count) is not int or expected_count < 1
            or not isinstance(values, list) or len(values) != expected_count
            or any(type(x) not in [int, float] or not math.isfinite(x) or x < 0 for x in values)):
        raise ValueError('Complete finite nonnegative latency samples required')
    ordered=sorted(values)
    def quantile(q):
        rank=(len(ordered)-1)*q
        lower=math.floor(rank);upper=math.ceil(rank)
        return ordered[lower]+(ordered[upper]-ordered[lower])*(rank-lower)
    return {'count':len(values),'unit':'milliseconds','method':'linear interpolation at (n-1)*q',
            'p50':quantile(.5),'p95':quantile(.95),'median':quantile(.5),'minimum':ordered[0],'maximum':ordered[-1]}


def evaluate(raw):
    if (any(type(raw[k]) is not int for k in ['measuredCount','warmupCount','concurrency','providerCalls'])
            or raw['mode']!='offline-scripted-latency' or raw['measuredCount']!=30 or raw['warmupCount']!=3
            or raw['concurrency']!=1 or raw['realModelExecuted'] is not False or raw['providerCalls']!=0):
        raise ValueError('Unsupported latency measurement profile')
    result={}
    for name,calls,reads,identity in [('runtime',2,1,'runID'),('toolFreeModelPort',1,0,'requestID')]:
        rows=raw[name]
        if not isinstance(rows,list) or len(rows)!=33 or any(not isinstance(row[identity],str) or not row[identity] for row in rows) or len({row[identity] for row in rows})!=33:
            raise ValueError('Missing or duplicate measurement runs')
        if any(type(row['modelCalls']) is not int or type(row['worldReads']) is not int or row['warmup'] is not (index<3) or row['modelCalls']!=calls or row['worldReads']!=reads
               or (name=='runtime' and row['state']!='COMPLETED') for index,row in enumerate(rows)):
            raise ValueError('Unqualified latency sample')
        summarize([row['milliseconds'] for row in rows[:3]],3)
        result[name]=summarize([row['milliseconds'] for row in rows[3:]])
    return result
