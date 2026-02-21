# FHIR IG Publisher — Performance Experiments

This repo builds the [HL7 FHIR IG Publisher](https://github.com/HL7/fhir-ig-publisher) and [FHIR Core](https://github.com/hapifhir/org.hl7.fhir.core) from source, with experimental performance optimizations applied to both. The submodules point to forks containing these changes.

## Quick Start

```bash
# Prerequisites: Java 17+, Maven 3.9+

git clone --recurse-submodules https://github.com/jmandel/igpublisher-perf.git
cd igpublisher-perf

./rebuild.sh          # Build FHIR Core, then IG Publisher
./rebuild.sh run -ig /path/to/your/ig
```

## Build System

The IG Publisher depends on FHIR Core. `rebuild.sh` builds Core first (`mvn install` to `~/.m2/repository`), then builds the Publisher against it.

| Command | What it does |
|---------|-------------|
| `./rebuild.sh all` | Build Core + Publisher (default) |
| `./rebuild.sh core` | Build Core only |
| `./rebuild.sh publisher` | Build Publisher only |
| `./rebuild.sh run [args]` | Run the built Publisher |

The script auto-detects the Core version from `pom.xml` and passes it to the Publisher build via `-Dcore_version`. It also deletes the Publisher's `target/` directory before building to ensure the maven-shade-plugin produces a fresh fat JAR.

## Repository Structure

```
igpublisher-perf/
├── org.hl7.fhir.core/       ← submodule (jmandel/org.hl7.fhir.core, branch describe-duration-secs)
├── fhir-ig-publisher/        ← submodule (jmandel/fhir-ig-publisher, branch perf-optimizations)
├── rebuild.sh                ← build script
├── JOURNAL.md                ← detailed profiling notes
└── README.md
```

---

## Performance Results

Profiled with JFR against US Core 9.0.0. A/B benchmarked: 3 runs each, same warm terminology cache, same machine.

```
Upstream avg:  3:54
Optimized avg: 2:41
Improvement:   31.2%  (73 seconds saved per build)
```

Optimized runs are also more consistent (4s variance vs 17s upstream).

### Phase Breakdown

| Phase | Upstream | Optimized | Change |
|-------|----------|-----------|--------|
| Check profiles & code systems | 26s | 15s | -44% |
| Previous Version Comparison | 58s | 41s | -29% |
| Generate Spreadsheets | 41s | 29s | -28% |
| Processing Provenance Records | 8s | 7s | -10% |

## Changes

### FHIR Core (8 files changed)

| File | Change | PR |
|------|--------|----|
| `CanonicalResourceManager.java` | `drop()`: added reverse index for O(1) key removal instead of scanning the entire map. `getList()`: use `IdentityHashMap` for O(n) deduplication instead of `List.contains()` which was O(n²). Reuse a single `MetadataResourceVersionComparator` instance instead of allocating one per `see()` call. | [#2322](https://github.com/hapifhir/org.hl7.fhir.core/pull/2322) |
| `FHIRPathEngine.java` | Cache `allTypes` and `primitiveTypes` in a static `WeakHashMap` keyed by `IWorkerContext`. Previously every `new FHIRPathEngine()` iterated all StructureDefinitions to rebuild these. | [#2323](https://github.com/hapifhir/org.hl7.fhir.core/pull/2323) |
| `XhtmlParser.java` | Make `elements`, `attributes`, and `definedEntities` maps `static final`. Previously rebuilt on every parser instantiation. | [#2324](https://github.com/hapifhir/org.hl7.fhir.core/pull/2324) |
| `SimpleWorkerContext.java` | Cache the result of `getResourceNames()` (lazy-init, `volatile`). Previously rebuilt the list on every call. | [#2325](https://github.com/hapifhir/org.hl7.fhir.core/pull/2325) |
| `TerminologyCache.java` | Instead of rewriting the entire cache file to disk after every single terminology lookup, mark caches as dirty and flush every 5 seconds. A shutdown hook ensures nothing is lost. On cold caches this was the dominant cost — writing files of size 1, 2, 3, ... N entries is O(n²) I/O. | [#2326](https://github.com/hapifhir/org.hl7.fhir.core/pull/2326) |
| `SemverParser.java` | Cache `parseSemver()` results in a `ConcurrentHashMap`. Called frequently from version comparison code. | [#2325](https://github.com/hapifhir/org.hl7.fhir.core/pull/2325) |
| `NpmPackageIndexBuilder.java` | Share a single static `JsonFactory` instance instead of creating one per use. | [#2325](https://github.com/hapifhir/org.hl7.fhir.core/pull/2325) |

### IG Publisher (2 files changed)

| File | Change | PR |
|------|--------|----|
| `ValidationServices.java` | Cache NamingSystem URLs in a `HashSet` for O(1) lookup in `resolveURL()`, instead of iterating all NamingSystems each time. | [#1254](https://github.com/HL7/fhir-ig-publisher/pull/1254) |
| `PublisherGenerator.java` | Send usage statistics via a daemon thread instead of blocking. | [#1254](https://github.com/HL7/fhir-ig-publisher/pull/1254) |

## Profiling Methodology

1. Run with JFR: `-XX:StartFlightRecording=settings=profile` (10ms sampling)
2. Identify hotspots by leaf-frame CPU sample counts
3. Trace call chains to find algorithmic root causes
4. Verify fixes are present in the fat JAR using `javap -p` on extracted classes

See [JOURNAL.md](JOURNAL.md) for the full profiling history with raw sample counts, phase timings across runs, and notes on approaches that didn't work (e.g., parallelizing `PreviousVersionComparator` — reverted due to thread-safety issues in Core internals).
