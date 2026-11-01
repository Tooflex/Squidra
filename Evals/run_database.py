#!/usr/bin/env python3
import json
import os
from pathlib import Path
import subprocess
import sys
from metrics import score_queries
from run import ROOT, digest

DATA = ROOT / 'fixtures/evals/world-queries.v1.json'
OUTPUT = ROOT / '.build/evals/world-queries-v1'


def main():
    credentials, port = sys.argv[1:3]
    values = dict(line.split('=', 1) for line in Path(credentials).read_text().splitlines())
    env = dict(os.environ, SQUIDRA_TEST_DB_PORT=port, SQUIDRA_TEST_DB_PASSWORD=values['POSTGRES_PASSWORD'])
    expected = DATA.with_suffix('.sha256').read_text().strip()
    if digest(DATA) != expected:
        raise ValueError('Frozen query dataset hash mismatch')
    dataset = json.loads(DATA.read_text())
    if dataset['version'] != 'authored-world-queries-1' or dataset['mode'] != 'deterministic_postgres_queries':
        raise ValueError('Unsupported query benchmark version')
    subprocess.run([sys.executable, '-m', 'unittest', 'Evals.test_metrics'], cwd=ROOT, check=True)
    subprocess.run(['swift', 'build', '--force-resolved-versions', '--product', 'squidra-eval-database'], cwd=ROOT, check=True)
    binary = Path(subprocess.check_output(['swift', 'build', '--show-bin-path'], cwd=ROOT, text=True).strip()) / 'squidra-eval-database'
    OUTPUT.mkdir(parents=True, exist_ok=True)
    path = OUTPUT / 'predictions.json'
    path.unlink(missing_ok=True)
    subprocess.run([str(binary), str(DATA), str(path)], cwd=ROOT, env=env, check=True, timeout=60)
    output = json.loads(path.read_text())
    predictions = output['predictions']
    metrics = score_queries(dataset['cases'], predictions)
    baseline_predictions = [dict(id=c['id'], locations=[], uncertainty=['noEvidence'], sources=[]) for c in dataset['cases']]
    baseline = score_queries(dataset['cases'], baseline_predictions)
    source_paths = sorted(p for folder in ['SquidraDomain', 'SquidraWorld', 'SquidraPostgres'] for p in (ROOT / 'Sources' / folder).rglob('*.swift'))
    source_paths += [ROOT / 'Evals/Database/main.swift', ROOT / 'Evals/metrics.py']
    metadata = dict(mode=dataset['mode'], dataset_version=dataset['version'], annotation_version=dataset['annotationVersion'], dataset_sha256=expected,
                    git_revision=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
                    worktree_dirty=bool(subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT, text=True).strip()),
                    package_resolved_sha256=digest(ROOT / 'Package.resolved'), source_sha256={str(p.relative_to(ROOT)): digest(p) for p in source_paths},
                    migration_sha256={str(p.relative_to(ROOT)): digest(p) for p in sorted((ROOT / 'Migrations').rglob('*.sql'))},
                    database_version=output['databaseVersion'], model_id=None, model_version=None, model_calls=0,
                    limitations='Authored deterministic queries and source attribution on isolated PostgreSQL; not AI answer quality.')
    for name, value in [('results', dict(metrics=metrics, metadata=metadata, cases=dataset['cases'], predictions=predictions)),
                        ('baseline', dict(name='always_no_evidence', metrics=baseline, metadata=metadata, predictions=baseline_predictions)),
                        ('thresholds', dict(thresholds=metrics['thresholds'], scope='authored_database_queries_only'))]:
        (OUTPUT / (name + '.json')).write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + '\n')
    print(json.dumps(metrics), flush=True)
    if not metrics['passed']:
        return 1
    print('SQUIDRA_TEST_PASS:database_query_metrics', flush=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
