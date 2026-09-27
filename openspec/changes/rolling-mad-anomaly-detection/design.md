## Context

The extension currently keeps SQL functions thin: PostgreSQL supplies an
ordered `float8[]`, Rust validates and processes it, and pgrx returns either a
plain array or ordered table rows. Existing validation and smoke coverage live
in `src/lib.rs` and `sql/poc.sql`; Dockerized benchmark scripts measure both
in-query work and request/container cost. See `proposal.md` for motivation and
the capability spec for the externally visible contract.

The pinned Augurs 0.10.2 release exposes an `outlier` feature and
`augurs::outlier::MADDetector`. The public README/source documentation is
inconsistent about its maturity, so the implementation plan treats the pinned
crate source and compile behavior as authoritative. Closed Augurs PR #359 was a
Wasm/Go binding proof of concept and was superseded by PR #367; neither changes
the required rolling-window SQL contract.

## Goals / Non-Goals

**Goals:**

- Build on the pinned Augurs outlier/MAD capability where its semantics and
  public API are compatible, adding only the adapter behavior required for a
  stateless rolling SQL function.
- Preserve one-row-per-input alignment and make warm-up and zero-MAD behavior
  explicit in both Rust and PostgreSQL tests.
- Establish reproducible cost evidence for correctness-first window processing
  at 2,880, 8,640, and 43,200 observations.
- Keep the API compatible with direct measurement arrays and MSTL remainder
  arrays, while documenting caller-owned ordering and timestamp mapping.

**Non-Goals:**

- Online mutable detector state, event persistence, persistence thresholds, or
  SynchroGuard integration.
- Timestamp handling, resampling, interpolation, seasonal adjustment, peer
  comparison, or automatic MSTL invocation.
- Adding a third-party rolling-statistics dependency before benchmark evidence
  shows that the straightforward implementation is insufficient.

## Decisions

### Assess and selectively reuse Augurs before adding adapter logic

First enable/check the pinned `augurs` `outlier` feature and verify the actual
available API. Augurs' current `MADDetector` accepts aligned series and
calculates one global median plus separate lower and upper deviation medians;
it returns a constant band across timestamps. It does not expose
`window_size`, `min_samples`, current-value exclusion, or the required zero-MAD
result semantics. Therefore it cannot be used as a direct implementation of
`ts_mad_detect` without changing the specified behavior.

Where the API is compatible, reuse Augurs types or calculations rather than
copying them. For the required trailing contract, keep a small adapter-local
calculation for each eligible index: copy the preceding slice into scratch
storage, sort it to find the median, compute absolute deviations from that
median, sort those values, and find MAD. Use the conventional midpoint for
even-sized sorted inputs.

This preserves Augurs as the first reuse path without forcing a global,
cross-series detector into a different rolling contract. It also avoids a
complex two-heaps-with-deletions implementation until benchmark evidence shows
that sorting each window is a material runtime or CPU problem. If the pinned
feature cannot be enabled cleanly or offers no reusable public operation, do
not retain it solely for provenance; record that result and keep the adapter
implementation dependency-minimal.

### Represent nullable SQL input and output explicitly

Accept `Vec<Option<f64>>` at the pgrx boundary so NULL elements can be rejected
with an index-specific error, as existing changepoint and decomposition
functions do. Use PostgreSQL-defaulted arguments for `threshold = 3.5` and
`min_samples = NULL`, resolving the latter to `window_size` before processing.
Return `TableIterator` rows containing the zero-based index, nullable numeric
detection fields, and readiness/outlier booleans. Positional SQL examples will
be preferred because `values` has existing PostgreSQL named-notation hazards.

### Exclude the current observation and preserve aligned warm-up rows

For index `i`, derive the window bounds from `i` and `window_size` before
reading the current value. Emit a warm-up row with NULL detection fields until
`i >= min_samples`; once ready, use all available preceding samples up to the
window limit. This preserves the caller's row alignment and prevents current
value leakage even when an explicit minimum is smaller than the window.

### Make arithmetic failure-safe

Use finite checks after median, MAD, bounds, and score calculations. A finite
input that would overflow a bound or score calculation must become a clear
PostgreSQL calculation error rather than an infinite or NaN output. Zero MAD is
handled before division, with the exact matching/different-value behavior in
the spec.

### Validate through focused Rust tests and the existing Docker path

Unit tests will cover validation, even-window medians, exclusion of the current
sample, known spikes, warm-up, explicit minimums, level-shift adaptation,
zero-MAD cases, output finiteness, and independent calls. Extend `sql/poc.sql`
with deterministic stable, spike, level-shift, timestamp-mapping, and
remainder-shaped arrays plus each invalid-input class. Run the complete
Dockerized smoke test through `bash scripts/poc.sh` so generated PostgreSQL
signatures and SQL errors are exercised.

### Benchmark the Augurs-backed and adapter paths separately when applicable

Add a rolling-MAD SQL workload and shell harness following the existing
Dockerized benchmark pattern. Run 2,880 samples (30 days at 15 minutes), 8,640
samples (90 days at 15 minutes), and 43,200 samples (30 days at 1 minute),
consuming every returned row. If an Augurs-backed path is used for any
sub-calculation, report it separately from adapter work; otherwise record that
the pinned API was not semantically reusable. Measure in-query detector time,
request time, and sampled PostgreSQL container CPU; report iterations,
environment, and results in `benchmark.md`, with build, installation, and
fixture setup outside the measured operation.

### Document the public SQL contract and compatibility boundary

Update `README.md` with the signature, positional-call example, trailing
window and sample-count semantics, zero-MAD behavior, timestamp join pattern,
raw-versus-residual usage, and the fact that no event or persistence logic is
included. State that the function is an additive PostgreSQL API and does not
alter existing forecast, decomposition, seasonality, or changepoint behavior.

## Risks / Trade-offs

- **[Sorting every trailing window may be expensive for large histories]** →
  Record benchmark evidence at all requested sizes and defer a sliding data
  structure until its complexity is justified.
- **[Finite input can still overflow derived bounds or scores]** → Validate
  every derived numeric result and raise a clear error instead of returning
  non-finite SQL values.
- **[A zero-MAD window can produce a NULL score for a true outlier]** → Document
  that `is_outlier` is authoritative in this case and test it explicitly.
- **[Callers may treat point anomalies as operational events]** → Keep the API
  stateless and domain-neutral, and document persistence/escalation as an
  external concern.
- **[Large SQL arrays consume backend memory]** → Keep the input-size boundary
  visible in benchmark results and avoid adding hidden buffering beyond the
  per-window scratch calculation.

## Migration Plan

1. Add the Rust helper, pgrx function, focused tests, SQL smoke assertions, and
   benchmark harness.
2. Build/install the PostgreSQL 17 extension image and run `bash scripts/poc.sh`.
3. Run the rolling-MAD benchmark, record results, and update README guidance.
4. Run applicable formatting, lint, dependency, workflow, and secret checks.
5. Roll back by installing the previous extension package; no tables, stored
   detector state, or data migration are introduced.

## Security and validation

The trust boundary is the PostgreSQL caller supplying arrays and configuration
to Rust. Validation rejects malformed numeric input and configuration before
calculation; the function performs no SQL relation lookup, filesystem access,
authentication, authorization, or secret handling. Security validation will
include the repository's deterministic secret scan, workflow/dependency checks,
and SQL invalid-input assertions. Resource consumption is the main operational
risk, so benchmark CPU and latency evidence is part of acceptance rather than
an implicit performance claim.
