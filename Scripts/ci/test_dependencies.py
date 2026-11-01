#!/usr/bin/env python3
import copy
import json
from pathlib import Path
import tempfile
import unittest
import dependencies as gate

class Contract(unittest.TestCase):
    def setUp(self):
        self.swift=json.loads((gate.ROOT/'Package.resolved').read_text())
        self.npm=json.loads((gate.ROOT/'web/package-lock.json').read_text())
        self.expected=gate.inventory(self.swift,self.npm)
        self.report={'results':[{'source':{'path':path,'type':'lockfile'},'packages':[{'package':dict(zip(['ecosystem','name','version'],key))} for key,count in packages.items() for _ in range(count)]} for path,packages in self.expected.items()]}
    def test_exact_inventory(self):
        self.assertEqual(gate.validate(self.report,self.expected,0)['status'],'passed')
    def test_missing_duplicate_or_substituted_package_fails(self):
        for mode in ['missing','duplicate','wrong-version']:
            report=copy.deepcopy(self.report);entries=report['results'][0]['packages']
            if mode=='missing':entries.pop()
            elif mode=='duplicate':entries.append(entries[0])
            else:entries[0]['package']['version']='0.0.0'
            with self.assertRaises(ValueError):gate.validate(report,self.expected,0)
    def test_error_empty_report_or_exit_mismatch_fails(self):
        for code in [2,127,130]:
            with self.assertRaises(ValueError):gate.validate(self.report,self.expected,code)
        with self.assertRaises(ValueError):gate.validate({'results':[]},self.expected,0)
        with self.assertRaises(ValueError):gate.validate(self.report,self.expected,1)
    def test_advisory_blocks_and_cannot_hide_under_zero_exit(self):
        self.report['results'][0]['packages'][0]['vulnerabilities']=[{'id':'SYNTHETIC-ADVISORY'}]
        self.assertEqual(gate.validate(self.report,self.expected,1)['status'],'vulnerabilities')
        with self.assertRaises(ValueError):gate.validate(self.report,self.expected,0)
    def test_unsupported_and_empty_lockfiles_fail(self):
        self.swift['pins'][0]['state'].pop('version')
        with self.assertRaises(ValueError):gate.inventory(self.swift,self.npm)
        self.swift=json.loads((gate.ROOT/'Package.resolved').read_text());self.npm['packages']={}
        with self.assertRaises(ValueError):gate.inventory(self.swift,self.npm)
    def test_live_known_vulnerable_dependency_blocks(self):
        with tempfile.TemporaryDirectory() as temporary:
            path=Path(temporary)/'package-lock.json'
            path.write_text(json.dumps({'name':'negative-fixture','lockfileVersion':3,'packages':{'':{'name':'negative-fixture'},'node_modules/lodash':{'version':'4.17.20'}}}))
            report=gate.scan(gate.ROOT/'Package.resolved',path)
            self.assertEqual(report['status'],'vulnerabilities')
            self.assertTrue(report['advisory_ids'])
            self.assertIn({'ecosystem':'npm','name':'lodash','version':'4.17.20'},report['affected_packages'])
            self.assertEqual(report['npm_packages'],1)

if __name__=='__main__':
    suite=unittest.defaultTestLoader.loadTestsFromTestCase(Contract)
    result=unittest.TextTestRunner().run(suite)
    if not result.wasSuccessful() or result.skipped or result.testsRun!=6:raise SystemExit(1)
    print('SQUIDRA_TEST_PASS:dependency_gate_contracts')
