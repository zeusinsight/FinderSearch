"""Compare warm filename queries through fsearch IPC and native Spotlight metadata queries.

This measures backend access paths, not either application's rendered UI.
Fixtures are authored, scoped to one temporary home directory, and removed on exit.
"""

import argparse
import datetime
import json
import math
from pathlib import Path
import platform
import socket
import statistics
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runs', type=int, default=30)
    parser.add_argument('--files', type=int, default=10000)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if args.runs < 2 or args.files < 3:
        parser.error('Use at least 2 runs and 3 files.')
    with tempfile.TemporaryDirectory(prefix='FinderSearch-benchmark-helper-') as build:
        binary = str(Path(build) / 'spotlight')
        source = Path(__file__).with_name('benchmark_spotlight.swift')
        subprocess.run(['swiftc', '-swift-version', '5', str(source), '-o', binary], check=True)
        with subprocess.Popen([binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True) as helper:
            with socket.socket(socket.AF_UNIX) as sock:
                sock.settimeout(15)
                sock.connect(str(Path.home() / 'Library/Application Support/FSearch/fsearch.sock'))
                with sock.makefile('rwb') as stream, tempfile.TemporaryDirectory(prefix='FinderSearch-benchmark-', dir=Path.home()) as directory:
                    root = Path(directory)
                    names = ['atlas-notes', 'orbit-budget', 'pixel-design']
                    for index in range(args.files):
                        (root / f'{names[index % 3]}-{index:05d}.txt').write_text('Authored benchmark fixture.\n')
                    queries = [f'{name}-{index:05d}.txt' for index, name in enumerate(names)]

                    def fsearch(query):
                        stream.write(json.dumps({'q': "'" + query, 'in': directory, 'limit': 500}).encode() + b'\n')
                        stream.flush()
                        reply = json.loads(stream.readline())
                        if not reply['ok']:
                            raise RuntimeError(reply.get('error', 'fsearch failed'))
                        return {Path(hit['path']).name for hit in reply.get('hits', [])}

                    def spotlight(query):
                        helper.stdin.write(json.dumps({'scope': directory, 'name': query}) + '\n')
                        helper.stdin.flush()
                        result = json.loads(helper.stdout.readline())
                        if not result['ok']:
                            raise RuntimeError('Spotlight query did not finish gathering.')
                        return set(result['names'])

                    subprocess.run(['/usr/bin/mdimport', directory], capture_output=True, check=True)
                    print('Waiting for both indexes to find all three authored queries...', flush=True)
                    deadline = time.monotonic() + 120
                    while True:
                        ready = all(fsearch(query) == spotlight(query) == {query} for query in queries)
                        if ready:
                            break
                        if time.monotonic() >= deadline:
                            raise RuntimeError('Both indexes did not become ready; no timing comparison was recorded.')
                        time.sleep(0.5)

                    rows = []
                    for query in queries:
                        timings = {'fsearch_ipc_ms': [], 'spotlight_native_ms': []}
                        for index in range(args.runs + 3):
                            methods = [('fsearch_ipc_ms', fsearch), ('spotlight_native_ms', spotlight)]
                            if index % 2:
                                methods.reverse()
                            for key, method in methods:
                                start = time.perf_counter_ns()
                                matches = method(query)
                                elapsed = (time.perf_counter_ns() - start) / 1e6
                                if matches != {query}:
                                    raise RuntimeError('Result sets changed; benchmark aborted.')
                                if index >= 3:
                                    timings[key].append(elapsed)
                        def summary(values):
                            return {'median_ms': round(statistics.median(values), 3), 'p95_ms': round(sorted(values)[math.ceil(len(values) * .95) - 1], 3)}
                        rows.append({'query': query, 'matches': 1, 'fsearch_ipc': summary(timings['fsearch_ipc_ms']), 'spotlight_native': summary(timings['spotlight_native_ms']), 'samples': timings})
                    report = {
                        'date_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                        'hardware': subprocess.check_output(['sysctl', '-n', 'machdep.cpu.brand_string'], text=True).strip(),
                        'macos': platform.mac_ver()[0], 'fixture_files': args.files, 'runs_per_query': args.runs, 'warmups_per_query': 3,
                        'measurement': 'Warm backend wall time: persistent fsearch socket vs native NSMetadataQuery in a persistent helper process. Includes IPC overhead for both; excludes UI, debounce, initial indexing. Each native Spotlight query runs from start to finish gathering. One exact filename per query, same folder, verified equal result sets. Does not establish whole-disk or Finder UI performance.',
                        'rows': rows,
                    }
                    encoded = json.dumps(report, indent=2) + '\n'
                    if args.output:
                        args.output.parent.mkdir(parents=True, exist_ok=True)
                        args.output.write_text(encoded)
                    print(encoded)

if __name__ == '__main__':
    main()
