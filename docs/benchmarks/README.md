# Filename search benchmark

Recorded 2026-10-09 on Apple M4 / macOS 27.0. These results cover one machine,
three exact filename queries, and warm indexes. They are not a measurement of the
Finder UI or a claim about every search workload.

| Query | fsearch median / p95 | Spotlight median / p95 |
| --- | ---: | ---: |
| `atlas-notes-00000.txt` | 0.494 / 1.830 ms | 7.109 / 7.263 ms |
| `orbit-budget-00001.txt` | 1.135 / 1.860 ms | 7.058 / 7.336 ms |
| `pixel-design-00002.txt` | 0.858 / 2.447 ms | 7.305 / 9.875 ms |

## Method

The script creates 10,000 small text files in an isolated folder under the current
user's home directory. Both engines must find the three target filenames before
measurement begins. Each query has one match, with equal result sets verified on
every run. Fixtures are removed at the end.

- fsearch: persistent JSON-lines socket, exact-match query, folder scope, limit 500.
- Spotlight: a persistent Swift helper creates a native `NSMetadataQuery` with a
  filename predicate and the same folder scope. Timing ends after the query's
  finish-gathering notification and result retrieval.
- Both measurements include their IPC round trip. Neither launches a process for
  each measured query. Helper compilation/startup and initial indexing are excluded.
- Three warmups are discarded, then 30 samples are recorded per query. Execution
  order alternates. Median and nearest-rank p95 are reported.

Spotlight is the indexing/search service behind Finder. This harness uses its
public metadata API; it does not instrument Finder's own internal query lifecycle,
ranking, result rendering, or UI caching. fsearch also supports fuzzy queries,
which this exact-filename comparison does not measure. The UI's 50 ms debounce,
folder browsing, thumbnails, and whole-disk search are outside this benchmark.

## Reproduce

Build and launch FinderSearch, wait for its index, then run from the repo root:

```sh
python3 scripts/benchmark_search.py --files 10000 --runs 30 --output docs/benchmarks/search.json
```

Requires Python 3, Swift development tools, and working Spotlight indexing in your
home folder. An unavailable index or unequal results aborts the comparison rather
than recording a misleading speed result. Numbers will vary with hardware, OS,
index state, filesystem, and other running work.

[Raw samples and environment](search.json) · [Python harness](../../scripts/benchmark_search.py)
· [Native Spotlight helper](../../scripts/benchmark_spotlight.swift)

[Apple's metadata query API](https://developer.apple.com/documentation/foundation/nsmetadataquery)
