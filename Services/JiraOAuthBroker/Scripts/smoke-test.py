"""Local-only executable check; all credentials and registration values are synthetic."""
import json
import os
from pathlib import Path
import socket
import subprocess
import time
import urllib.request

binary = Path(__file__).resolve().parents[1] / '.build/debug/jira-oauth-broker'
with socket.socket() as probe:
    probe.bind(('127.0.0.1', 0))
    port = probe.getsockname()[1]
environment = dict(os.environ, AGENTDESK_JIRA_CLIENT_ID='synthetic-client',
                   AGENTDESK_JIRA_CALLBACK='https://broker.example/callback', AGENTDESK_JIRA_PORT=str(port))
process = subprocess.Popen([str(binary)], env=environment, stdin=subprocess.PIPE,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
process.stdin.write(b'synthetic-secret\n')
process.stdin.close()
try:
    deadline = time.monotonic() + 5
    while True:
        try:
            request = urllib.request.Request(f'http://127.0.0.1:{port}/v1/attempts',
                data=json.dumps({'challenge': 'A' * 43}).encode(), headers={'Content-Type': 'application/json'})
            with urllib.request.urlopen(request, timeout=1) as response:
                assert response.status == 201 and response.headers['Cache-Control'] == 'no-store'
            break
        except OSError:
            if time.monotonic() > deadline or process.poll() is not None:
                raise
            time.sleep(.05)
    process.terminate()
    assert process.wait(timeout=5) == 0, 'SIGTERM must exit gracefully'
    output = process.stdout.read() + process.stderr.read()
    assert b'synthetic-secret' not in output
    failed = subprocess.run([str(binary)], input=b'synthetic-secret', env={'PATH': os.environ['PATH']},
                            capture_output=True, timeout=5)
    assert failed.returncode == 1
    assert b'synthetic-secret' not in failed.stdout + failed.stderr
    print('PASS: startup, loopback request, SIGTERM shutdown, invalid configuration, secret-safe diagnostics')
finally:
    if process.poll() is None:
        process.kill()
        process.wait()
