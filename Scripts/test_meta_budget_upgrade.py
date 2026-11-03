"""Offline migration/ceiling contracts; never reads or modifies the real ledger."""
import base64
import copy
from datetime import datetime, timezone
import importlib.util
import json
from pathlib import Path
import unittest
import uuid

spec=importlib.util.spec_from_file_location('budget',Path(__file__).with_name('test-meta-live.py'))
b=importlib.util.module_from_spec(spec);spec.loader.exec_module(b)

class UpgradeTests(unittest.TestCase):
    def legacy(self, count=9):
        old=b.initial()
        for i in range(count):
            item=b.reserve(old,b.MODELS['sam' if i%2 else 'spark'],datetime(2026,11,1,tzinfo=timezone.utc))
            item['status']='interrupted' if i%2 else 'failed'
            item['report']={'fixture':i,'estimateNotInvoice':True}
        return json.dumps(old,indent=2).encode()
    def test_preserve_history_bytes_and_all_reserved_amounts(self):
        raw=self.legacy();ledger=b.upgrade_legacy_bytes(raw)
        self.assertEqual(base64.b64decode(ledger['history']['base64']),raw)
        self.assertEqual(b.validate(ledger),9000)
        self.assertEqual(b.legacy_history(ledger),json.loads(raw))
    def test_four_future_calls_fit_no_fifth_and_no_refund(self):
        ledger=b.upgrade_legacy_bytes(self.legacy());history=copy.deepcopy(ledger['history'])
        for _ in range(4):
            attempt=b.reserve(ledger,b.MODELS['spark'],datetime(2026,11,4,tzinfo=timezone.utc))
            attempt['status']='failed'
        self.assertEqual(b.validate(ledger),10000)
        self.assertEqual(ledger['history'],history)
        before=copy.deepcopy(ledger)
        with self.assertRaises(b.Refused):b.reserve(ledger,b.MODELS['spark'],datetime(2026,11,4,tzinfo=timezone.utc))
        self.assertEqual(ledger,before)
    def test_full_legacy_budget_stays_full(self):
        ledger=b.upgrade_legacy_bytes(self.legacy(10))
        with self.assertRaises(b.Refused):b.reserve(ledger,b.MODELS['spark'],datetime(2026,11,4,tzinfo=timezone.utc))
        self.assertEqual(b.validate(ledger),10000)
    def test_wonder_and_sam_cannot_use_reduced_envelope(self):
        ledger=b.upgrade_legacy_bytes(self.legacy())
        for model in ('wonder','sam'):
            with self.assertRaises(b.Refused):b.reserve(ledger,b.MODELS[model],datetime(2026,11,4,tzinfo=timezone.utc))
        self.assertEqual(b.validate(ledger),9000)
    def test_expiry_and_naive_time_refuse_without_write(self):
        ledger=b.upgrade_legacy_bytes(self.legacy());before=copy.deepcopy(ledger)
        for now in (datetime(2026,11,5,tzinfo=timezone.utc),datetime(2026,11,4)):
            with self.assertRaises(b.Refused):b.reserve(ledger,b.MODELS['spark'],now)
        self.assertEqual(ledger,before)
    def test_corruption_duplicate_ids_and_changed_amount_refused(self):
        ledger=b.upgrade_legacy_bytes(self.legacy())
        for field,value in [('base64','bad!'),('sha256','0'*64)]:
            bad=copy.deepcopy(ledger);bad['history'][field]=value
            with self.assertRaises(b.Refused):b.validate(bad)
        item=b.reserve(ledger,b.MODELS['spark'],datetime(2026,11,4,tzinfo=timezone.utc))
        item['id']=b.legacy_history(ledger)['attempts'][0]['id']
        with self.assertRaises(b.Refused):b.validate(ledger)
        item['id']=str(uuid.uuid4());item['reservedEURCents']=1
        with self.assertRaises(b.Refused):b.validate(ledger)

    def test_atomic_migration_retry_preserves_new_reservations(self):
        import tempfile, hashlib
        spec=importlib.util.spec_from_file_location('upgrade',Path(__file__).with_name('upgrade-meta-budget.py'))
        upgrade=importlib.util.module_from_spec(spec);spec.loader.exec_module(upgrade)
        with tempfile.TemporaryDirectory() as temp:
            directory=Path(temp).resolve();directory.chmod(0o700)
            path=directory/'live-budget.json';raw=self.legacy();path.write_bytes(raw);path.chmod(0o600)
            lock=directory/'live-budget.lock';lock.touch(mode=0o600)
            digest=hashlib.sha256(raw).hexdigest()
            with self.assertRaises(upgrade.budget.Refused):upgrade.upgrade(directory,'0'*64)
            self.assertEqual(path.read_bytes(),raw)
            self.assertEqual(upgrade.upgrade(directory,digest),9000)
            ledger=b.decode_ledger(path.read_bytes())
            b.reserve(ledger,b.MODELS['spark'],datetime(2026,11,4,tzinfo=timezone.utc));b.save(path,ledger)
            after=path.read_bytes()
            self.assertEqual(upgrade.upgrade(directory,digest),9250)
            self.assertEqual(path.read_bytes(),after)
            import fcntl
            with lock.open('r+') as handle:
                fcntl.flock(handle,fcntl.LOCK_EX|fcntl.LOCK_NB)
                with self.assertRaises(BlockingIOError):upgrade.upgrade(directory,digest)
            self.assertEqual(path.read_bytes(),after)

    def test_ambiguous_json_or_oversized_output_cannot_replace_ledger(self):
        import tempfile
        raw=self.legacy().replace(b'"schemaVersion": 1',b'"schemaVersion": 1, "schemaVersion": 1')
        with self.assertRaises(b.Refused):b.upgrade_legacy_bytes(raw)
        ledger=b.upgrade_legacy_bytes(self.legacy())
        item=b.reserve(ledger,b.MODELS['spark'],datetime(2026,11,4,tzinfo=timezone.utc))
        item['report']={'payload':'x'*262144}
        with tempfile.TemporaryDirectory() as temp:
            path=Path(temp)/'budget.json';path.write_bytes(b'original')
            with self.assertRaises(b.Refused):b.save(path,ledger)
            self.assertEqual(path.read_bytes(),b'original')

if __name__=='__main__':unittest.main()
