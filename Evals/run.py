#!/usr/bin/env python3
"""Export a reproducible authored-component benchmark; never label it AI accuracy."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
from metrics import score

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / 'fixtures/evals/components.v1.json'
OUTPUT = ROOT / '.build/evals/components-v1'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write(name, value):
    (OUTPUT / name).write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + '\n')


def main():
    expected = DATA.with_suffix('.sha256').read_text().strip()
    if digest(DATA) != expected:
        raise ValueError('Frozen dataset hash mismatch; version annotation changes explicitly')
    dataset = json.loads(DATA.read_text())
    if dataset['version'] != 'authored-components-1' or dataset['mode'] != 'deterministic_components':
        raise ValueError('Unsupported dataset version or evaluation mode')
    subprocess.run([sys.executable, '-m', 'unittest', 'Evals.test_metrics'], cwd=ROOT, check=True)
    print('SQUIDRA_TEST_PASS:metric_regressions', flush=True)
    subprocess.run(['swift', 'build', '--force-resolved-versions', '--product', 'squidra-eval'], cwd=ROOT, check=True)
    binary = Path(subprocess.check_output(['swift', 'build', '--show-bin-path'], cwd=ROOT, text=True).strip()) / 'squidra-eval'
    OUTPUT.mkdir(parents=True, exist_ok=True)
    prediction_path = OUTPUT / 'predictions.json'
    prediction_path.unlink(missing_ok=True)
    subprocess.run([str(binary), str(DATA), str(prediction_path)], cwd=ROOT, check=True, timeout=60)
    predictions = json.loads(prediction_path.read_text())
    metrics = score(dataset['cases'], predictions)
    baseline_predictions = [dict(id=c['id'], prediction=False) for c in dataset['cases']]
    baseline = score(dataset['cases'], baseline_predictions)
    sources = sorted(p for folder in ['SquidraDomain', 'SquidraTemporal', 'SquidraSpatial', 'SquidraPerception']
                     for p in (ROOT / 'Sources' / folder).rglob('*.swift')) + [ROOT / 'Evals/Runner/main.swift', ROOT / 'Evals/metrics.py']
    metadata = dict(mode=dataset['mode'], dataset_version=dataset['version'], annotation_version=dataset['annotationVersion'],
                    dataset_sha256=expected, package_resolved_sha256=digest(ROOT / 'Package.resolved'),
                    git_revision=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
                    worktree_dirty=bool(subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT, text=True).strip()),
                    source_sha256={str(p.relative_to(ROOT)): digest(p) for p in sources},
                    swift_version=subprocess.check_output(['swift', '--version'], cwd=ROOT, text=True).strip(),
                    model_id=None, model_version=None, model_calls=0, repeated_ai_evaluation=False,
                    limitations='30 authored synthetic component cases; not an estimate of real-world model/sensor quality.')
    write('baseline.json', dict(name='always_false_no_movement', predictions=baseline_predictions, metrics=baseline, metadata=metadata))
    write('results.json', dict(metrics=metrics, metadata=metadata, cases=dataset['cases'], predictions=predictions))
    write('thresholds.json', dict(thresholds=metrics['thresholds'], scope='authored_components_only'))
    print('SQUIDRA_TEST_PASS:complete_exports', flush=True)
    print(json.dumps(metrics, allow_nan=False), flush=True)
    if not metrics['passed']:
        return 1
    print('SQUIDRA_TEST_PASS:component_thresholds', flush=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
