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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("issue")
    parser.add_argument("--filter", help="Override the mapped regex, e.g. to check an empty selection")
    args = parser.parse_args()
    manifest = json.loads((ROOT / "Scripts/issue-tests.json").read_text())
    suite = manifest.get(args.issue)
    if suite is None or suite.get("kind") != "xctest":
        parser.error("Issue has no executable XCTest mapping; no test was run")
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
