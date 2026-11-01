import copy
import importlib.util
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('release_report', Path(__file__).with_name('release_report.py'))
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)


class ReleaseReportTests(unittest.TestCase):
    def summary(self):
        return dict(issue='EXAMPLE', selected=3, passed=3, failed=0, skipped=0, not_executed=0, status='passed')

    def test_complete_matching_execution(self):
        value=self.summary();encoded=json.dumps(value)
        self.assertEqual(report.validate_execution(0, 'diagnostics\n'+encoded, encoded, 'EXAMPLE'), value)

    def test_nonzero_command_cannot_use_success_report(self):
        encoded=json.dumps(self.summary())
        with self.assertRaises(ValueError):report.validate_execution(1, encoded, encoded, 'EXAMPLE')

    def test_empty_incomplete_skipped_flaky_failed_and_invalid_counts_rejected(self):
        for key,value in [('selected',0),('passed',2),('failed',1),('skipped',1),('not_executed',1),('status','flaky'),('selected',True),('passed',3.0),('failed',-1)]:
            with self.subTest(key=key,value=value):
                bad=self.summary();bad[key]=value
                with self.assertRaises(ValueError):report.validate_summary(bad,'EXAMPLE')

    def test_missing_or_cross_suite_report_rejected(self):
        for value in [{},[],dict(self.summary(),issue='OTHER')]:
            with self.assertRaises(ValueError):report.validate_summary(value,'EXAMPLE')
        with self.assertRaises(ValueError):report.validate_execution(0,'','{}','EXAMPLE')

    def test_stored_and_stdout_counts_must_agree(self):
        changed=dict(self.summary(),selected=4,passed=4)
        with self.assertRaises(ValueError):report.validate_execution(0,json.dumps(self.summary()),json.dumps(changed),'EXAMPLE')

    def test_source_mutation_dirty_state_and_commit_change_fail(self):
        source={'commit':'a','dirty':False,'files_sha256':{'file':'digest'},'inventory_sha256':'hash'}
        report.require_same_source(source,copy.deepcopy(source))
        for key,value in [('commit','b'),('dirty',True),('files_sha256',{'file':'changed'})]:
            changed=copy.deepcopy(source);changed[key]=value
            with self.assertRaises(ValueError):report.require_same_source(source,changed)
        dirty=dict(source,dirty=True)
        with self.assertRaises(ValueError):report.require_same_source(dirty,dirty)


    def test_xctest_requires_complete_unique_successful_xml(self):
        value=dict(self.summary(), selected=1, passed=1)
        good=b'<testsuites><testsuite><testcase classname="Suite" name="testA"/></testsuite></testsuites>'
        report.validate_execution(0,'XCTest output',json.dumps(value),'EXAMPLE','xctest',good)
        for xml in [None,b'<testsuites/>',b'broken',good.replace(b'/></testsuite>',b'><skipped/></testcase></testsuite>'),good.replace(b'<testcase classname="Suite" name="testA"/>',b'<testcase classname="Suite" name="testA"/>'*2)]:
            with self.assertRaises((ValueError,report.ET.ParseError)):
                report.validate_execution(0,'XCTest output',json.dumps(value),'EXAMPLE','xctest',xml)


if __name__ == '__main__':
    outcome=unittest.main(exit=False)
    if outcome.result.wasSuccessful():
        print('SQUIDRA_TEST_PASS:release_report_contracts')
    else:
        raise SystemExit(1)
