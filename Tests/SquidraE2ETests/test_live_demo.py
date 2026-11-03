import copy
from datetime import datetime, timezone
import importlib.util
from pathlib import Path
import unittest
import uuid
import base64
import json
import os
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from live_demo import admission, execute
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('budget_contract', ROOT / 'Scripts/test-meta-live.py')
budget = importlib.util.module_from_spec(spec)
spec.loader.exec_module(budget)


class AdmissionTests(unittest.TestCase):
    def setUp(self):
        self.ledger = budget.initial()
        self.now = datetime(2026, 11, 1, tzinfo=timezone.utc)

    def test_requires_explicit_consent_without_mutating_ledger(self):
        before = copy.deepcopy(self.ledger)
        for consent in (None, '', 'true', '0'):
            with self.assertRaises(RuntimeError):
                admission(budget, self.ledger, consent, self.now)
        self.assertEqual(self.ledger, before)

    def test_whole_two_question_envelope(self):
        for count in range(11):
            self.ledger['attempts'] = [dict(id=str(uuid.uuid4()), model='muse-spark-1.3',
                reservedEURCents=1000, status='reserved', report=None) for _ in range(count)]
            before = copy.deepcopy(self.ledger)
            if count <= 6:
                self.assertEqual(admission(budget, self.ledger, '1', self.now), count * 1000)
            else:
                with self.assertRaises(RuntimeError):
                    admission(budget, self.ledger, '1', self.now)
            self.assertEqual(self.ledger, before)

    def test_expiry_includes_complete_run_margin(self):
        for now in (datetime(2026, 11, 1, 23, 53, tzinfo=timezone.utc),
                    datetime(2026, 11, 2, tzinfo=timezone.utc), datetime(2026, 11, 1)):
            with self.assertRaises(RuntimeError):
                admission(budget, self.ledger, '1', now)
        self.assertEqual(admission(budget, self.ledger, '1',
            datetime(2026, 11, 1, 23, 52, 59, tzinfo=timezone.utc)), 0)

    def test_invalid_or_refunded_allowance_rejected(self):
        self.ledger['authorizedEURCents'] = 20000
        with self.assertRaises(budget.Refused):
            admission(budget, self.ledger, '1', self.now)


class ServerLaunchTests(unittest.TestCase):
    def test_explicit_loopback_origin_without_starting_provider(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            identity = root / 'identity.json'
            identity.write_text(json.dumps({'actor': str(uuid.uuid4()), 'subject': str(uuid.uuid4())}))
            for inherited in (None, 'https://unrelated.example'):
                env = {'SQUIDRA_TEST_DB_PORT': '5432', 'SQUIDRA_TEST_DB_PASSWORD': 'fixture-only'}
                if inherited is not None:
                    env['SQUIDRA_UI_ORIGIN'] = inherited
                original = dict(env)
                with patch('live_demo.preflight', return_value=0), patch('live_demo.subprocess.Popen', side_effect=RuntimeError('stop-before-launch')) as launch:
                    with self.assertRaisesRegex(RuntimeError, 'stop-before-launch'):
                        execute(root, root, env, identity, root/'scenario', root/'evidence', root)
                    self.assertEqual(launch.call_args.kwargs['env']['SQUIDRA_UI_ORIGIN'], 'http://127.0.0.1:3000')
                    self.assertEqual(launch.call_args.kwargs['env']['SQUIDRA_PORT'], '0')
                self.assertEqual(env, original)


class HTTPClientTests(unittest.TestCase):
    def run_client(self, fault=None):
        identity = {key: str(uuid.uuid4()) for key in ('actor', 'subject', 'desk', 'drawer', 'frame')}
        scenario = dict(monday='2026-10-26T00:00:00Z', tuesday='2026-10-27T00:00:00Z', wednesday='2026-10-28T00:00:00Z')
        expected = {key: dict(sourceEventID=str(uuid.uuid4()), sourceID='authored-test',
            observedAt=scenario['monday'], recordedAt=scenario['tuesday'], confidence=.8)
            for key in ('mondayEarly', 'mondayCorrected')}
        posts = []
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass
            def send(self, body, status=200):
                self.send_response(status)
                self.end_headers()
                self.wfile.write(body.encode())
            def do_POST(self):
                posts.append(json.loads(self.rfile.read(int(self.headers['Content-Length']))))
                self.server.run = {k: str(uuid.uuid4()) for k in ('runId', 'threadId', 'requestId', 'traceId')}
                run = self.server.run
                run.update(schemaVersion='1', status='/api/v1/runs/'+run['runId'])
                run['events'] = run['status']+'/events'
                self.send(json.dumps(run), 202)
            def do_GET(self):
                run = self.server.run
                name, location = ('mondayEarly', 'desk') if len(posts) == 1 else ('mondayCorrected', 'drawer')
                source = expected[name]
                proof = dict(schemaVersion='1', id=source['sourceEventID'], subjectId=identity['subject'],
                    locationId=identity[location], frameId=identity['frame'], source=source['sourceID'],
                    observedAt=source['observedAt'], recordedAt=source['recordedAt'], confidence=.8,
                    basis='observed', timeZone='Etc/UTC', freshness='stale')
                if fault == 'source':
                    proof['source'] = 'unrelated-source'
                answer = dict(schemaVersion='1', actorId=identity['actor'], requestId=run['requestId'],
                    intent='historical', status='grounded', text='Authored offline test answer', uncertainty=[],
                    evidence=[proof], claims=[dict(kind='location', subjectId=identity['subject'],
                        locationId=identity[location], frameId=identity['frame'], basis='observed',
                        minimumSourceConfidence=.8, citationIds=[proof['id']])])
                if fault == 'request':
                    answer['requestId'] = str(uuid.uuid4())
                message = str(uuid.uuid4())
                events = [dict(type='RUN_STARTED', runId=run['runId'], threadId=run['threadId'], protocolVersion='1.0'),
                    dict(type='CUSTOM', name='squidra.grounded_answer.v1', value=answer),
                    dict(type='TEXT_MESSAGE_START', messageId=message, role='assistant'),
                    dict(type='TEXT_MESSAGE_CONTENT', messageId=message, delta=answer['text']),
                    dict(type='TEXT_MESSAGE_END', messageId=message),
                    dict(type='RUN_FINISHED', runId=run['runId'], threadId=run['threadId'], outcome=dict(type='success'))]
                frames = []
                for index, event in enumerate(events, 1):
                    event['timestamp'] = 0
                    cursor = dict(schemaVersion='1', runId=run['runId'], actorId=identity['actor'], afterSequence=str(index))
                    encoded = base64.urlsafe_b64encode(json.dumps(cursor).encode()).decode().rstrip('=')
                    frames.append('id: '+encoded+'\ndata: '+json.dumps(event)+'\n\n')
                self.send(''.join(frames))
        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        worker = threading.Thread(target=server.serve_forever)
        worker.start()
        try:
            with tempfile.TemporaryDirectory() as directory:
                paths = [Path(directory)/name for name in ('identity.json', 'scenario.json', 'evidence.json', 'report.json')]
                for path, data in zip(paths, (identity, scenario, expected)):
                    path.write_text(json.dumps(data))
                env = {k: os.environ[k] for k in ('PATH', 'HOME') if k in os.environ}
                env.update(SQUIDRA_HISTORICAL_META_LIVE='1', SQUIDRA_DEMO_ORIGIN=f'http://127.0.0.1:{server.server_port}', SQUIDRA_DEMO_TOKEN='a'*64)
                result = subprocess.run(['node', 'Tests/SquidraE2ETests/live_demo.mjs', *map(str, paths)],
                    cwd=ROOT, env=env, capture_output=True, timeout=15)
                report = json.loads(paths[-1].read_text())
                self.assertEqual(result.returncode == 0, fault is None)
                self.assertEqual(report['outcome'], 'passed' if fault is None else 'failed')
                self.assertEqual(len(posts), 2 if fault is None else 1)
                self.assertTrue(all(item['intent'] == 'historical' for item in posts))
                self.assertNotIn('a'*64, paths[-1].read_text())
        finally:
            server.shutdown()
            server.server_close()
            worker.join()

    def test_two_questions_and_correlated_evidence(self):
        self.run_client()

    def test_wrong_source_fails_without_second_submission(self):
        self.run_client('source')

    def test_wrong_request_fails_without_retry(self):
        self.run_client('request')


if __name__ == '__main__':
    subprocess.run(['npm', 'run', 'build'], cwd=ROOT / 'web', check=True)
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromModule(__import__(__name__)))
    if not result.wasSuccessful() or result.testsRun != 8 or result.skipped:
        raise SystemExit(1)
    print('SQUIDRA_TEST_PASS:historical_meta_contracts')
