"""Back up the shared fsearch index after the app is quit and permissions change."""

import argparse
import datetime
import os
from pathlib import Path
import signal
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args()
    project = Path(__file__).resolve().parent.parent
    binaries = [
        project / "vendor/fsearch/target/release/fsearch",
        project / "dist/FinderSearch.app/Contents/Helpers/fsearch",
    ]
    allowed = {str(binary) + " serve" for binary in binaries}
    processes = []
    for line in subprocess.check_output(["ps", "-axo", "pid=,command="], text=True).splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2:
            processes.append((int(parts[0]), parts[1]))

    app_binary = str(project / "dist/FinderSearch.app/Contents/MacOS/FinderSearch")
    if any(command == app_binary or command.startswith(app_binary + " ") for _, command in processes):
        parser.error("Quit FinderSearch before reindexing.")
    for _, command in processes:
        if command.endswith(" serve") and Path(command[:-6]).name == "fsearch" and command not in allowed:
            parser.error("Another fsearch installation is running. Quit it before backing up the shared index.")

    daemon_pids = [pid for pid, command in processes if command in allowed]
    for pid in daemon_pids:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    deadline = time.monotonic() + 5
    for pid in daemon_pids:
        while True:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                break
            if time.monotonic() >= deadline:
                parser.error("Daemon has not stopped; the index was left untouched. Try again after it exits.")
            time.sleep(0.1)

    cache = Path.home() / "Library/Application Support/FSearch"
    if cache.exists():
        stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
        backup = cache.with_name("FSearch-backup-" + stamp)
        cache.rename(backup)
        print(f"Previous index preserved at {backup}")
    print("Reopen FinderSearch to build a fresh index with the new permissions.")


if __name__ == "__main__":
    main()
