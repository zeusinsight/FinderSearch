# Third-party software

FinderSearch's filename search is powered by **fsearch**, created by **Noah Dunnagan**.

- Upstream: https://github.com/noahdunnagan/fsearch
- Version: 0.2.1 with opt-in document content indexing
- Base revision: `88e63fdf850cf7749deae8198b187accd21f8ba5`
- Document support: `1bbfe8a4b401047b17eb98706324556187735f2c` ([upstream PR #37](https://github.com/noahdunnagan/fsearch/pull/37))
- License: [MIT](vendor/fsearch/LICENSE)

The upstream source is retained in `vendor/fsearch` with local document extraction and settings support. Its
copyright and license notice are included in every built app at
`Contents/Resources/fsearch-LICENSE`. `vendor/fsearch/Cargo.lock` records its Rust
dependencies; the build uses locked dependency resolution.

FinderSearch's native interface, browsing workflows, caching, and app integration
are separate from the upstream search engine. Engine benchmarks published by
fsearch do not measure FinderSearch's complete UI response time.

The document index/read integration adapts ATS-aerothermal-solutions/fsearch
commit `6bcfdba7a72c61f2a083631a0e288dc93dd3555f`. The parser allocator, bounded
collector and cache approach adapt joshwhiteley/fsearch (MIT, Copyright 2026
Josh Whiteley). See [DOCUMENT-LICENSE](vendor/fsearch/DOCUMENT-LICENSE), also
included in built apps. PDF uses macOS PDFKit, DOC/DOCX use textutil, and Excel
uses Calamine. Cargo.lock records dependency versions.
