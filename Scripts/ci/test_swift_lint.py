#!/usr/bin/env python3
import copy
from pathlib import Path
import unittest
import swift_lint as gate

class Contract(unittest.TestCase):
    def setUp(self):
        self.files={'Sources/Test.swift':b'import Foundation\n'}
        self.log="Linting 'Test.swift' (1/1)\nDone linting! Found 0 violations, 0 serious in 1 file.\n"
    def test_exact_empty_report(self):
        self.assertEqual(gate.validate([],self.log,self.files,Path('/tmp/snapshot'),0)['status'],'passed')
    def test_missing_progress_or_summary_fails(self):
        for log in ['',self.log.replace('(1/1)','(1/2)'),self.log.replace('1 file.','2 files.')]:
            with self.assertRaises(ValueError):gate.validate([],log,self.files,Path('/tmp/snapshot'),0)
    def test_nonzero_tool_failure_cannot_pass(self):
        for code in [1,2,127]:
            with self.assertRaises(ValueError):gate.validate([],self.log,self.files,Path('/tmp/snapshot'),code)
    def test_actual_safe_and_four_regressions(self):
        self.assertEqual(gate.scan(self.files)['status'],'passed')
        data=b'import Foundation\nimport Foundation\nfunc example(_ value: String?) {\n if let _ = value { print("present") }\n let redundant = value ?? nil\n unusedLabel: while true { break }\n print(redundant as Any)\n}\n'
        report=gate.scan({'Sources/Test.swift':data})
        self.assertEqual(report['status'],'findings')
        self.assertEqual({item['rule'] for item in report['findings']},gate.RULES)
        self.assertEqual(len(report['findings']),4)
    def test_inline_suppression_fails(self):
        with self.assertRaises(ValueError):gate.scan({'Sources/Test.swift':b'// swiftlint:disable all\nimport Foundation\n'})
    def test_source_paths_cannot_escape(self):
        with self.assertRaises(ValueError):gate.scan({'../Outside.swift':b'import Foundation\n'})

if __name__=='__main__':
    result=unittest.TextTestRunner().run(unittest.defaultTestLoader.loadTestsFromTestCase(Contract))
    if not result.wasSuccessful() or result.skipped or result.testsRun!=6:raise SystemExit(1)
    print('SQUIDRA_TEST_PASS:swift_lint_contracts')
