import concurrent.futures
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
import uuid
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('decisions', ROOT/'Scripts/account-erasure/decisions.py')
d = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d)


class Tests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name).resolve()
        self.actor = str(uuid.uuid4())
    def tearDown(self):
        self.temp.cleanup()
    def test_missing_authority_never_means_empty(self):
        with self.assertRaises(FileNotFoundError): d.snapshot(self.path)
        with self.assertRaises(FileNotFoundError): d.request_erasure(self.path, self.actor)
    def test_initialize_never_resets_existing_decisions(self):
        d.initialize(self.path); d.request_erasure(self.path, self.actor)
        with self.assertRaises(FileExistsError): d.initialize(self.path)
        self.assertEqual(d.snapshot(self.path)['actors'], (self.actor,))
    def test_idempotent_minimal_durable_record(self):
        d.initialize(self.path)
        first = d.request_erasure(self.path, self.actor)
        self.assertEqual(first, d.request_erasure(self.path, self.actor))
        raw = json.loads((self.path/'decisions.json').read_text())
        self.assertEqual(raw, {'schemaVersion': 1, 'actors': [self.actor]})
        self.assertEqual((self.path/'decisions.json').stat().st_mode & 0o777, 0o600)
    def test_concurrent_requests_preserve_all_actors(self):
        d.initialize(self.path)
        actors = [str(uuid.uuid4()) for _ in range(24)]
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            list(pool.map(lambda actor: d.request_erasure(self.path, actor), actors + actors))
        self.assertEqual(d.snapshot(self.path)['actors'], tuple(sorted(actors)))
    def test_malformed_and_noncanonical_authority_fail_without_repair(self):
        d.initialize(self.path)
        for raw in [b'{}', b'{"schemaVersion":1,"actors":[],"actors":[]}', b'{"schemaVersion":true,"actors":[]}\n', b'[]', b'not-json']:
            (self.path/'decisions.json').write_bytes(raw)
            with self.assertRaises((ValueError, TypeError)): d.request_erasure(self.path, self.actor)
            self.assertEqual((self.path/'decisions.json').read_bytes(), raw)
    def test_links_and_permissions_rejected(self):
        d.initialize(self.path)
        file = self.path/'decisions.json'
        file.chmod(0o644)
        with self.assertRaises(ValueError): d.snapshot(self.path)
        file.chmod(0o600)
        os.link(file, self.path/'linked')
        with self.assertRaises(ValueError): d.snapshot(self.path)
        (self.path/'linked').unlink()
        file.rename(self.path/'original')
        file.symlink_to(self.path/'original')
        with self.assertRaises(OSError): d.snapshot(self.path)
    def test_invalid_actor_does_not_write(self):
        d.initialize(self.path)
        before = d.snapshot(self.path)
        for actor in ['person', self.actor.upper(), '{'+self.actor+'}', '../actor']:
            with self.assertRaises(ValueError): d.request_erasure(self.path, actor)
        self.assertEqual(d.snapshot(self.path), before)
    def test_interrupted_publish_preserves_previous_decisions(self):
        d.initialize(self.path); d.request_erasure(self.path, self.actor)
        before = d.snapshot(self.path)
        with patch.object(d.os, 'replace', side_effect=OSError('fixture publication failure')):
            with self.assertRaises(OSError): d.request_erasure(self.path, str(uuid.uuid4()))
        self.assertEqual(d.snapshot(self.path), before)
        self.assertFalse(list(self.path.glob('.pending-*')))
    def test_fifo_and_public_directory_fail(self):
        os.mkfifo(self.path/'decisions.json', 0o600)
        with self.assertRaises(ValueError): d.snapshot(self.path)
        self.path.chmod(0o755)
        with self.assertRaises(ValueError): d.snapshot(self.path)
        self.path.chmod(0o700)

if __name__ == '__main__':
    result = unittest.TextTestRunner().run(unittest.defaultTestLoader.loadTestsFromTestCase(Tests))
    if not result.wasSuccessful() or result.testsRun != 9 or result.skipped: raise SystemExit(1)
    print('SQUIDRA_TEST_PASS:erasure_decision_registry')
