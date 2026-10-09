# Third-party software

FinderSearch's filename search is powered by **fsearch**, created by **Noah Dunnagan**.

- Upstream: https://github.com/noahdunnagan/fsearch
- Vendored revision: `af9476d39ec98108552670adf6badbbd77331b0a`
- License: [MIT](vendor/fsearch/LICENSE)

The upstream source is retained in `vendor/fsearch` without modifications. Its
copyright and license notice are included in every built app at
`Contents/Resources/fsearch-LICENSE`. `vendor/fsearch/Cargo.lock` records its Rust
dependencies; the build uses locked dependency resolution.

FinderSearch's native interface, browsing workflows, caching, and app integration
are separate from the upstream search engine. Engine benchmarks published by
fsearch do not measure FinderSearch's complete UI response time.
