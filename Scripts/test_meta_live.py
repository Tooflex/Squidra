import datetime as dt
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('meta_live', Path(__file__).with_name('test-meta-live.py'))
live = importlib.util.module_from_spec(spec)
spec.loader.exec_module(live)


class MetaLiveBudgetTests(unittest.TestCase):
    now = dt.datetime(2026, 11, 1, tzinfo=dt.timezone.utc)

    def test_cumulative_cap_and_failures_never_refund(self):
        ledger = live.initial()
        for index in range(10):
            item = live.reserve(ledger, live.MODELS['spark'], self.now)
            item['status'] = ('failed', 'interrupted', 'passed')[index % 3]
        self.assertEqual(live.validate(ledger), 10000)
        with self.assertRaises(live.Refused):
            live.reserve(ledger, live.MODELS['wonder'], self.now)
        self.assertEqual(len(ledger['attempts']), 10)

    def test_durable_reserved_attempt_survives_restart(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'budget.json'
            ledger = live.initial()
            item = live.reserve(ledger, live.MODELS['wonder'], self.now)
            live.save(path, ledger)
            restored = live.json.loads(live.private_file(path, 65536))
            self.assertEqual(restored['attempts'][0]['id'], item['id'])
            self.assertEqual(restored['attempts'][0]['status'], 'reserved')
            self.assertEqual(live.validate(restored), 1000)
            live.reserve(restored, live.MODELS['sam'], self.now)
            self.assertEqual(live.validate(restored), 2000)

    def test_expired_snapshot_or_corrupt_ledger_refuses(self):
        with self.assertRaises(live.Refused):
            live.reserve(live.initial(), live.MODELS['spark'], dt.datetime(2026, 11, 2, tzinfo=dt.timezone.utc))
        for key, value in [('authorizedEURCents', 10001), ('schemaVersion', True), ('fx', {}), ('attempts', {})]:
            ledger = live.initial();ledger[key] = value
            with self.assertRaises(live.Refused):
                live.validate(ledger)
        ledger = live.initial();live.reserve(ledger, live.MODELS['spark'], self.now)
        ledger['attempts'].append(ledger['attempts'][0].copy())
        with self.assertRaises(live.Refused):
            live.validate(ledger)

    def test_private_file_refuses_symlink_permissions_and_oversize(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'key';path.write_bytes(b'fake');path.chmod(0o600)
            self.assertEqual(live.private_file(path, 4096), b'fake')
            link = Path(directory) / 'link';link.symlink_to(path)
            with self.assertRaises(OSError):
                live.private_file(link, 4096)
            path.chmod(0o644)
            with self.assertRaises(live.Refused):
                live.private_file(path, 4096)
            path.chmod(0o600);path.write_bytes(b'x' * 4097)
            with self.assertRaises(live.Refused):
                live.private_file(path, 4096)


class SAMReferenceQuotaTests(unittest.TestCase):
    def test_untrusted_dimensions_and_payload_are_bounded_before_decoder(self):
        spec = importlib.util.spec_from_file_location('sam_reference', Path(__file__).with_name('test-sam-reference.py'))
        module = importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        class NeverDecode:
            def image_segmentation_format(self):
                raise AssertionError('Decoder called before resource rejection')
        variants = [None, 'x' * 16385, '<0f>',
            '<0f>0<|mask;data=99999,1,!x|>', '<0f>0<|mask;data=0,1,!x|>',
            '<0f>0<|mask;data=1024,1024,!x|>,1<|mask;data=1,1,!x|>',
            '<0f>0<|mask;data=1,1,!x|>' * 17,
            '<0f>0<|box;x1=0;y1=0;x2=0;y2=0;w=999;h=512|><|mask;data=1,1,!x|>']
        for text in variants:
            with self.assertRaises(ValueError):
                module.decode({'segmentationText': text}, NeverDecode())
