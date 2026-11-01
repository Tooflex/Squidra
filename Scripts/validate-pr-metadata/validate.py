#!/usr/bin/env python3
"""Validate data only. Never print PR content or execute commands from metadata."""
import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path

START = '<!-- squidra-provenance:v1 -->'
END = '<!-- /squidra-provenance -->'
MAX_BYTES = 65536
SECRET = re.compile(r'(?i)(?:\b(?:MODEL_API_KEY|api[_-]?key|password|token|secret)\s*[:=]\s*["\']?[^\s,"\'}]+|\bBearer\s+[^\s"\']+|\bgh[pousr]_[A-Za-z0-9_]+|-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----)')


def redact(text):
    """Defense in depth for common credentials; never a complete secret detector."""
    return SECRET.sub('[REDACTED]', text)


def digest(manifest):
    return hashlib.sha256(json.dumps(manifest, sort_keys=True, separators=(',', ':'), ensure_ascii=True).encode()).hexdigest()


def unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('duplicate JSON key')
        result[key] = value
    return result


def text(value):
    if not isinstance(value, str) or not value.strip() or len(value) > 4096 or value.strip().lower() in {'todo', 'tbd', 'unavailable', 'not applicable'}:
        raise ValueError('missing or invalid text field')


def validate(body):
    if not isinstance(body, str) or len(body.encode()) > MAX_BYTES:
        raise ValueError('body size invalid')
    if redact(body) != body:
        raise ValueError('credential pattern detected; redact before publication')
    if body.count(START) != 1 or body.count(END) != 1:
        raise ValueError('exactly one provenance block required')
    payload = body.split(START)[1].split(END)[0].strip()
    if body.index(END) < body.index(START):
        raise ValueError('invalid block order')
    data = json.loads(payload, object_pairs_hook=unique, parse_constant=lambda _: (_ for _ in ()).throw(ValueError('nonfinite JSON')))
    required = {'issue', 'criteria', 'summary', 'trace', 'tool_manifest', 'tool_hash', 'usage', 'tests'}
    if not isinstance(data, dict) or set(data) != required:
        raise ValueError('invalid provenance fields')
    if type(data['issue']) is not int or not 1 <= data['issue'] <= 1000000000:
        raise ValueError('invalid issue')
    for field in ['criteria', 'tests']:
        if not isinstance(data[field], list) or not 1 <= len(data[field]) <= 64:
            raise ValueError('criteria and tests required')
        for value in data[field]:
            text(value)
    text(data['summary'])
    trace = data['trace']
    if not isinstance(trace, dict) or set(trace) != {'kind', 'id'} or trace['kind'] not in {'codex_thread', 'runtime_trace', 'local_record'}:
        raise ValueError('invalid trace kind')
    if not isinstance(trace['id'], str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._:-]{7,127}', trace['id']):
        raise ValueError('invalid trace id')
    manifest = data['tool_manifest']
    if not isinstance(manifest, dict) or set(manifest) != {'scope', 'tools'} or manifest['scope'] not in {'available_names', 'used_names'}:
        raise ValueError('invalid manifest scope')
    names = manifest['tools']
    if not isinstance(names, list) or not 1 <= len(names) <= 1024 or any(not isinstance(n, str) or not re.fullmatch(r'[A-Za-z0-9_.:-]{1,160}', n) for n in names):
        raise ValueError('invalid tool names')
    if names != sorted(set(names)) or data['tool_hash'] != digest(manifest):
        raise ValueError('manifest digest mismatch or noncanonical names')
    usage = data['usage']
    if not isinstance(usage, dict) or set(usage) != {'models', 'tokens', 'cost'}:
        raise ValueError('explicit usage required')
    for value in usage.values():
        text(value)
    # Reports intentionally contain no submitted strings, identifiers, or raw parser errors.
    return {'status': 'passed', 'criteria_count': len(data['criteria']), 'test_count': len(data['tests'])}


def main():
    parser = argparse.ArgumentParser()
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument('--body-file', type=Path)
    source.add_argument('--pr', type=int)
    args = parser.parse_args()
    try:
        if args.body_file:
            with args.body_file.open('rb') as stream:
                raw = stream.read(MAX_BYTES + 1)
            body = raw.decode('utf-8')
        else:
            if not 1 <= args.pr <= 1000000000:
                raise ValueError('invalid PR number')
            # Fixed repository and command. JSON body is data; no shell or head checkout.
            result = subprocess.run(['gh', 'api', f'repos/Tooflex/Squidra/pulls/{args.pr}', '--jq', '.body'], capture_output=True, timeout=30, check=True)
            body = result.stdout.decode('utf-8')
        print(json.dumps(validate(body), sort_keys=True))
        return 0
    except (ValueError, OSError, subprocess.SubprocessError, RecursionError):
        print('{"status":"failed","reason":"invalid or unavailable provenance; inspect locally and redact sensitive content"}')
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
