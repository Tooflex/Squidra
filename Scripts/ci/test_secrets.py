#!/usr/bin/env python3
import copy
import hashlib
import json
import unittest
import secrets as gate

class Contract(unittest.TestCase):
    def setUp(self):
        self.files={'fixture.py':b'public fixture'}
        self.finding={'RuleID':'github-pat','File':'/scan/fixture.py','StartLine':1,'Secret':'CANARY-MUST-NOT-APPEAR','Match':'CANARY-MUST-NOT-APPEAR'}
    def test_clean_report_and_status(self):
        self.assertEqual(gate.validate([],self.files,0)['status'],'passed')
        for code in [1,2,127]:
            with self.assertRaises(ValueError):gate.validate([],self.files,code)
    def test_finding_redaction_and_exit_mismatch(self):
        report=gate.validate([self.finding],self.files,1)
        self.assertNotIn('CANARY-MUST-NOT-APPEAR',json.dumps(report))
        self.assertEqual(report['status'],'findings')
        with self.assertRaises(ValueError):gate.validate([self.finding],self.files,0)
    def test_unknown_path_or_invalid_location_fails(self):
        for key,value in [('File','/scan/unlisted.py'),('StartLine',0),('RuleID','invalid rule')]:
            finding=dict(self.finding);finding[key]=value
            with self.assertRaises(ValueError):gate.validate([finding],self.files,1)
    def test_exception_requires_exact_file_and_location(self):
        report=gate.validate([self.finding],self.files,1)
        exception={'path':'fixture.py','line':1,'rule':'github-pat','file_sha256':hashlib.sha256(self.files['fixture.py']).hexdigest(),'reason':'Synthetic review contract'}
        self.assertEqual(gate.review(copy.deepcopy(report),self.files,[exception])['status'],'passed')
        self.assertEqual(gate.review(copy.deepcopy(report),{'fixture.py':b'changed'},[exception])['status'],'findings')
        exception['line']=2
        self.assertEqual(gate.review(copy.deepcopy(report),self.files,[exception])['status'],'findings')
    def test_actual_clean_and_synthetic_secret(self):
        self.assertEqual(gate.scan({'fixture.py':b'public_value = 42\n'})['status'],'passed')
        # Construct a nonfunctional token-shaped fixture, never a real credential.
        token='gh'+'p_'+hashlib.sha256(b'squidra-unregistered-synthetic-token').hexdigest()[:36]
        data=('github_token = "'+token+'" # gitleaks:allow\n').encode()
        report=gate.scan({'fixture.py':data,'.gitleaks.toml':b'[allowlist]\npaths = [".*"]\n','.gitleaksignore':b'*\n'})
        self.assertEqual(report['status'],'findings')
        self.assertTrue(any(item['rule']=='github-pat' for item in report['findings']))
        self.assertNotIn(token,json.dumps(report))
    def test_unsafe_snapshot_paths_fail(self):
        for path in ['../escape','/absolute']:
            with self.assertRaises(ValueError):gate.scan({path:b'public'})

if __name__=='__main__':
    result=unittest.TextTestRunner().run(unittest.defaultTestLoader.loadTestsFromTestCase(Contract))
    if not result.wasSuccessful() or result.skipped or result.testsRun!=6:raise SystemExit(1)
    print('SQUIDRA_TEST_PASS:secret_scan_contracts')
