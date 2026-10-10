# Third-party software

FinderSearch's filename search is powered by **fsearch**, created by **Noah Dunnagan**.

- Upstream: https://github.com/noahdunnagan/fsearch
- Vendored revision: `d753915440f0879004b8e11fd615eafc840cfa9c`
- License: [MIT](vendor/fsearch/LICENSE)

The upstream source is retained in `vendor/fsearch` without modifications. Its
copyright and license notice are included in every built app at
`Contents/Resources/fsearch-LICENSE`. `vendor/fsearch/Cargo.lock` records its Rust
dependencies; the build uses locked dependency resolution.

FinderSearch's native interface, browsing workflows, caching, and app integration
are separate from the upstream search engine. Engine benchmarks published by
fsearch do not measure FinderSearch's complete UI response time.
