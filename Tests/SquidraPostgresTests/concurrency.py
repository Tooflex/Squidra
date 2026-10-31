#!/usr/bin/env python3
"""Force two real PostgreSQL sessions to overlap on one ledger reservation."""
import json
import subprocess
import sys
import time

engine, container = sys.argv[1:]
base = [engine, 'exec', '-i', container, 'psql', '-X', '-A', '-t', '-q', '-v', 'ON_ERROR_STOP=1', '-U', 'squidra', '-d', 'squidra']
actor = '00000000-0000-0000-0000-000000000001'
run = '90000000-0000-0000-0000-000000000001'
trace = '90000000-0000-0000-0000-000000000002'

def scalar(sql):
    return subprocess.check_output(base, input=sql, text=True, timeout=10).strip()

scalar(f"INSERT INTO agent_runs(id,actor_id,trace_id) VALUES('{run}','{actor}','{trace}');")
query = f"SELECT row_to_json(r) FROM reserve_action('{actor}','{run}','world.concurrent','concurrent-key','1.0.0','object:1','{{}}','[]',decode(repeat('55',32),'hex')) AS r;"
processes = []

def start(name):
    args = [engine, 'exec', '--env', 'PGAPPNAME='+name, '-i', container,
            'psql', '-X', '-A', '-t', '-q', '-v', 'ON_ERROR_STOP=1', '-U', 'squidra', '-d', 'squidra']
    process = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    processes.append(process)
    return process

def wait_for(sql, process):
    until = time.monotonic()+20
    while time.monotonic() < until:
        if process.poll() is not None:
            raise RuntimeError('Database client exited before synchronization: '+process.stdout.read())
        if scalar(sql) == 't':
            return
        time.sleep(0.05)
    raise RuntimeError('Concurrent database synchronization timed out')

try:
    first = start('squidra-concurrency-first')
    first.stdin.write('BEGIN;\n'+query+'\n'); first.stdin.flush()
    wait_for("SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE application_name='squidra-concurrency-first' AND state='idle in transaction');", first)
    second = start('squidra-concurrency-second')
    second.stdin.write('BEGIN;\n'+query+'\nCOMMIT;\n'); second.stdin.flush(); second.stdin.close()
    wait_for("SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE application_name='squidra-concurrency-second' AND wait_event_type='Lock');", second)
    first.stdin.write('COMMIT;\n'); first.stdin.flush(); first.stdin.close()
    first.wait(timeout=10); second.wait(timeout=10)
    outputs = []
    for process in [first, second]:
        text = process.stdout.read()
        if process.returncode:
            raise RuntimeError('Database client failed: '+text)
        rows = [json.loads(line) for line in text.splitlines() if line.startswith('{')]
        if len(rows) != 1:
            raise RuntimeError('Missing or duplicate reservation response')
        outputs.append(rows[0])
    assert outputs[0]['created'] is True and outputs[1]['created'] is False
    assert outputs[0]['ledger_id'] == outputs[1]['ledger_id']
    assert scalar("SELECT count(*) FROM action_ledger WHERE tool_name='world.concurrent' AND idempotency_key='concurrent-key';") == '1'
    print('SQUIDRA_TEST_PASS:concurrent_reservation')
finally:
    for process in processes:
        if process.poll() is None:
            process.terminate()
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired: process.kill(); process.wait()
