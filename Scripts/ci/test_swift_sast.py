#!/usr/bin/env python3
import copy
import json
import unittest
import swift_sast as gate

class Contract(unittest.TestCase):
    def setUp(self):
        self.expected={'Sources/Test.swift':b'let x = 1'}
        self.clean={'paths':{'scanned':['Sources/Test.swift']},'errors':[],'results':[]}
    def test_exact_clean_report(self):
        self.assertEqual(gate.validate(self.clean,self.expected,0)['status'],'passed')
    def test_missing_duplicate_or_extra_coverage_fails(self):
        for paths in [[],['Sources/Test.swift']*2,['Sources/Test.swift','Sources/Other.swift']]:
            report=copy.deepcopy(self.clean);report['paths']['scanned']=paths
            with self.assertRaises(ValueError):gate.validate(report,self.expected,0)
    def test_parser_error_and_bad_exit_fail(self):
        for code in [2,3,127]:
            with self.assertRaises(ValueError):gate.validate(self.clean,self.expected,code)
        self.clean['errors']=[{'message':'synthetic parse error'}]
        with self.assertRaises(ValueError):gate.validate(self.clean,self.expected,0)
    def test_suppressed_or_unknown_finding_fails(self):
        for extra,rule in [({'is_ignored':True},'swift-insecure-md5'),({},'unknown')]:
            self.clean['results']=[{'path':'Sources/Test.swift','check_id':rule,'start':{'line':1},'extra':extra}]
            with self.assertRaises(ValueError):gate.validate(self.clean,self.expected,1)
    def test_finding_diagnostics_omit_source(self):
        self.clean['results']=[{'path':'Sources/Test.swift','check_id':'swift-insecure-md5','start':{'line':1},'extra':{'lines':'SECRET-CANARY'}}]
        summary=gate.validate(self.clean,self.expected,1)
        self.assertNotIn('SECRET-CANARY',json.dumps(summary))
        with self.assertRaises(ValueError):gate.validate(self.clean,self.expected,0)
    def test_actual_swift_safe_and_unsafe_fixtures(self):
        safe=b'import Crypto\nlet digest = SHA256.hash(data: bytes)\n// Insecure.MD5.hash(data: bytes)\n'
        self.assertEqual(gate.scan({'Sources/Safe.swift':safe})['status'],'passed')
        unsafe=b'import Crypto\nimport Security\nlet a = Insecure.MD5.hash(data: bytes) // nosemgrep\nlet b = Insecure.SHA1.hash(data: bytes)\nlet c = SecTrustSetExceptions(trust, exceptions)\n'
        report=gate.scan({'Sources/Unsafe.swift':unsafe})
        self.assertEqual(report['status'],'findings')
        self.assertEqual({f['rule'] for f in report['findings']},{'swift-insecure-md5','swift-insecure-sha1','swift-trust-exceptions'})
        self.assertEqual(len(report['findings']),3)
        with self.assertRaises(ValueError):gate.scan({'Sources/Broken.swift':b'func broken( { @@@'})

if __name__=='__main__':
    result=unittest.TextTestRunner().run(unittest.defaultTestLoader.loadTestsFromTestCase(Contract))
    if not result.wasSuccessful() or result.skipped or result.testsRun!=6:raise SystemExit(1)
    print('SQUIDRA_TEST_PASS:swift_sast_contracts')
