#!/usr/bin/env python3
"""Run a mapped XCTest suite and reject empty or incomplete test execution."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent


def run_command_suite(issue, suite):
    """Count explicit assertion markers emitted by a real integration command."""
    expected = suite.get("tests", [])
    command = suite.get("command", [])
    if (not expected or len(set(expected)) != len(expected)
            or not all(isinstance(name, str) and re.fullmatch(r"[a-z][a-z0-9_]*", name) for name in expected)
            or not command or not all(isinstance(arg, str) for arg in command)):
        raise ValueError("Invalid integration suite mapping")
    output = ROOT / ".build/issue-tests" / issue
    output.mkdir(parents=True, exist_ok=True)
    summary_path = output / "summary.json"
    summary_path.unlink(missing_ok=True)
    (output / "results.xml").unlink(missing_ok=True)
    result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True)
    print(result.stdout, end="")
    print(result.stderr, file=sys.stderr, end="")
    prefix = "SQUIDRA_TEST_PASS:"
    markers = [line[len(prefix):] for line in result.stdout.splitlines() if line.startswith(prefix)]
    valid = len(markers) == len(set(markers)) and set(markers).issubset(set(expected))
    passed = len(markers) if valid else 0
    status = ("execution_failed" if result.returncode else
              "invalid_report" if not valid else
              "passed" if passed == len(expected) else "incomplete_execution")
    summary = {"issue": issue, "selected": len(expected), "passed": passed,
               "failed": 0, "skipped": 0, "not_executed": len(expected) - passed, "status": status}
    summary_path.write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary), flush=True)
    return result.returncode or (0 if status == "passed" else 1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("issue")
    parser.add_argument("--filter", help="Override the mapped regex, e.g. to check an empty selection")
    args = parser.parse_args()
    manifest = json.loads((ROOT / "Scripts/issue-tests.json").read_text())
    suite = manifest.get(args.issue)
    if suite is None:
        parser.error("Issue has no executable mapping; no test was run")
    if suite.get("kind") == "command":
        if args.filter is not None:
            parser.error("Integration suites require all mapped assertion names; filters are not supported")
        return run_command_suite(args.issue, suite)
    if suite.get("kind") != "xctest":
        parser.error("Unsupported test suite kind; no test was run")
    pattern = args.filter if args.filter is not None else suite["filter"]
    try:
        regex = re.compile(pattern)
    except re.error as error:
        parser.error(f"Invalid test filter: {error}")
    if not pattern.strip():
        parser.error("Empty filters are not allowed")

    output = ROOT / ".build/issue-tests" / args.issue
    output.mkdir(parents=True, exist_ok=True)
    xml_path = output / "results.xml"
    summary_path = output / "summary.json"
    # A failed build/run must never reuse a previous successful report.
    xml_path.unlink(missing_ok=True)
    summary_path.unlink(missing_ok=True)
    summary = {"issue": args.issue, "selected": 0, "passed": 0,
               "failed": 0, "skipped": 0, "not_executed": 0, "status": "not_executed"}

    def finish(code):
        summary_path.write_text(json.dumps(summary, indent=2) + "\n")
        print(json.dumps(summary), flush=True)
        return code

    common = ["swift", "test", "--force-resolved-versions", "--disable-swift-testing"]
    listing = subprocess.run(common + ["list"], cwd=ROOT, text=True, capture_output=True)
    if listing.stderr:
        print(listing.stderr, file=sys.stderr, end="")
    if listing.returncode:
        summary["status"] = "discovery_failed"
        return finish(listing.returncode)
    discovered = [line.strip() for line in listing.stdout.splitlines()
                  if re.match(r"^[A-Za-z_][\w.]+/", line.strip())]
    selected = [name for name in discovered if regex.search(name)]
    summary["selected"] = len(selected)
    summary["not_executed"] = len(selected)
    if not selected:
        summary["status"] = "empty_selection"
        print("No tests selected; refusing to report success", file=sys.stderr)
        return finish(1)

    result = subprocess.run(common + ["--skip-build", "--parallel", "--num-workers", "2", "--filter", pattern,
                                     "--xunit-output", str(xml_path)], cwd=ROOT)
    if xml_path.exists():
        try:
            cases = ET.parse(xml_path).getroot().findall(".//testcase")
            summary["skipped"] = sum(case.find("skipped") is not None for case in cases)
            summary["failed"] = sum(case.find("failure") is not None or case.find("error") is not None
                                    for case in cases)
            summary["passed"] = len(cases) - summary["skipped"] - summary["failed"]
            summary["not_executed"] = max(0, len(selected) - len(cases))
        except (ET.ParseError, OSError):
            summary["status"] = "invalid_report"
            return finish(result.returncode or 1)
    else:
        cases = []
    if result.returncode:
        summary["status"] = "execution_failed"
        return finish(result.returncode)
    if len(cases) != len(selected) or summary["passed"] + summary["failed"] == 0:
        summary["status"] = "incomplete_execution"
        return finish(1)
    summary["status"] = "failed" if summary["failed"] else "passed"
    return finish(1 if summary["failed"] else 0)


if __name__ == "__main__":
    sys.exit(main())
