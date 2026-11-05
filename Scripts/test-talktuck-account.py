#!/usr/bin/env python3
"""Run the Mac account client against an isolated real loopback backend.

Uses synthetic data, an in-memory credential store and a fake SMS transport.
Does not read user recordings, contact external providers or change user Keychain.
"""
import argparse
import os
from pathlib import Path
import selectors
import signal
import subprocess
import tempfile
from urllib.parse import urlparse

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--server-repo', type=Path, required=True)
parser.add_argument('--node', type=Path, required=True)
args = parser.parse_args()
mac = Path(__file__).resolve().parents[1]
server = args.server_repo.resolve() / 'server'
node = args.node.resolve()
if not node.is_file() or not (server / 'test/support/mac-account-server.ts').is_file():
    parser.error('Node executable and the TalkTuck backend fixture must exist')
run = Path(tempfile.mkdtemp(prefix='talktuck-account-', dir=mac / '.build'))
binary = run / 'account-smoke'
with (run / 'compile.log').open('w') as log:
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
                    str(mac / 'Sources/TalkTuckAccountStore.swift'), str(mac / 'Sources/LibrarySync.swift'), str(mac / 'Sources/RecordingDomain.swift'),
                    str(mac / 'Tests/TalkTuckAccountSmoke.swift'), '-o', str(binary)],
                   check=True, stdout=log, stderr=subprocess.STDOUT, timeout=120)
with (run / 'server.log').open('w') as errorlog:
    child = subprocess.Popen([str(node), 'node_modules/tsx/dist/cli.mjs', 'test/support/mac-account-server.ts'],
                             cwd=server, stdout=subprocess.PIPE, stderr=errorlog,
                             text=True, start_new_session=True)
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(child.stdout, selectors.EVENT_READ)
            if not selector.select(timeout=15):
                raise RuntimeError('Loopback fixture did not become ready; inspect server.log')
        endpoint = child.stdout.readline().strip()
        parsed = urlparse(endpoint)
        if parsed.scheme != 'http' or parsed.hostname != '127.0.0.1' or not parsed.port:
            raise RuntimeError('Fixture did not return a loopback endpoint')
        result = subprocess.run([str(binary), endpoint], check=True, capture_output=True, text=True, timeout=45)
        (run / 'client.log').write_text(result.stdout + result.stderr)
        print(result.stdout.strip())
        print('Evidence:', run)
    finally:
        if child.poll() is None:
            os.killpg(child.pid, signal.SIGTERM)
        child.wait(timeout=10)
