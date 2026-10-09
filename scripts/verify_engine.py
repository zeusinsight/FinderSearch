"""Integration checks against the real daemon using isolated, authored files."""
import json
import socket
import tempfile
import time
from pathlib import Path

sock = socket.socket(socket.AF_UNIX)
sock.settimeout(10)
try:
    sock.connect(str(Path.home() / 'Library/Application Support/FSearch/fsearch.sock'))
except (FileNotFoundError, ConnectionRefusedError, socket.timeout) as error:
    sock.close()
    raise SystemExit('Start FinderSearch and wait for indexing before running engine checks.') from error
stream = sock.makefile('rwb')
def request(**fields):
    stream.write(json.dumps(fields).encode() + b'\n')
    stream.flush()
    result = json.loads(stream.readline())
    assert result['ok'], result
    return result

def wait_for(query, scope, expected, **filters):
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        result = request(q=query, **{'in': str(scope)}, **filters)
        if any(Path(hit['path']).name == expected for hit in result['hits']):
            return result
        time.sleep(.15)
    raise AssertionError(f'Missing {expected}')

with tempfile.TemporaryDirectory(prefix='FinderSearch-verify-', dir=Path.home()) as temporary:
    scope = Path(temporary)
    (scope / 'accuracy-report.txt').write_text('test fixture\n')
    (scope / 'accuracy-report.csv').write_text('test,fixture\n')
    (scope / 'accuracy-folder').mkdir()
    exact = wait_for('accuracy-report.txt', scope, 'accuracy-report.txt')
    assert Path(exact['hits'][0]['path']).name == 'accuracy-report.txt'
    wait_for('accurcy-report', scope, 'accuracy-report.txt')
    filtered = wait_for('accuracy', scope, 'accuracy-folder', kind='dir')
    assert all(hit['kind'] == 'dir' for hit in filtered['hits'])
    filtered = wait_for('accuracy', scope, 'accuracy-report.txt', ext='txt')
    assert all(hit['path'].endswith('.txt') for hit in filtered['hits'])
    (scope / 'accuracy-report.txt').rename(scope / 'renamed-report.txt')
    wait_for('renamed-report', scope, 'renamed-report.txt')
    (scope / 'renamed-report.txt').unlink()
    deadline = time.monotonic() + 8
    while request(q='renamed-report', **{'in': str(scope)})['hits']:
        assert time.monotonic() < deadline, 'Deleted file remained indexed'
        time.sleep(.15)
    print('PASS: exact ranking, typo matching, folder scope, type filters, live rename and deletion')
    print(f"Exact query engine time: {exact['took_us'] / 1000:.3f} ms")

stream.close()
sock.close()
