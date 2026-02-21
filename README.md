# FHIR IG Publisher — Local Development Build

Build the [HL7 FHIR IG Publisher](https://github.com/HL7/fhir-ig-publisher) from source along with its primary dependency, [FHIR Core](https://github.com/hapifhir/org.hl7.fhir.core), so that local changes in FHIR Core propagate into the IG Publisher binary.

## Prerequisites

- **Java 17+** (e.g. [Eclipse Temurin](https://adoptium.net/))
- **Apache Maven 3.9+**

## Quick Start

```bash
# Clone with submodules
git clone --recurse-submodules https://github.com/jmandel/igpublisher.git
cd igpublisher

# Build everything (FHIR Core → IG Publisher)
./rebuild.sh

# Run the built publisher
./rebuild.sh run -ig /path/to/your/ig
```

## How It Works

### Dependency Chain

```
org.hl7.fhir.core (FHIR Core library)
  └─ fhir-ig-publisher (IG Publisher)
       uses: org.hl7.fhir.r5, org.hl7.fhir.validation,
             org.hl7.fhir.convertors, org.hl7.fhir.utilities
```

The IG Publisher depends on FHIR Core artifacts (groupId `ca.uhn.hapi.fhir`). By building FHIR Core first with `mvn install`, its jars land in your local Maven repository (`~/.m2/repository/`). The IG Publisher build then resolves those same artifacts locally instead of downloading from Maven Central.

### Build Steps

| Step | What Happens |
|------|-------------|
| `./rebuild.sh core` | Builds FHIR Core and installs it to `~/.m2/repository` |
| `./rebuild.sh publisher` | Builds the IG Publisher with `-Dcore_version=<auto-detected>`, pulling FHIR Core from the local repo. Produces a fat JAR via maven-shade-plugin. Verifies the JAR contains the correct core version. |
| `./rebuild.sh all` | Runs both steps in order (default) |
| `./rebuild.sh run [args]` | Runs the built IG Publisher JAR |

### Making Changes

1. **Edit FHIR Core** — make your change in `org.hl7.fhir.core/`
2. **Rebuild Core** — `./rebuild.sh core` (installs updated jars to `~/.m2`)
3. **Rebuild Publisher** — `./rebuild.sh publisher` (picks up updated jars)
4. **Run** — `./rebuild.sh run -ig /path/to/ig`

For changes to the IG Publisher itself, skip step 1–2 and just run `./rebuild.sh publisher`.

### ⚠️ Version Mismatch Trap

**This is the single most dangerous pitfall in this build system.**

The IG Publisher resolves FHIR Core jars from `~/.m2/repository` by version string. If the version passed to `-Dcore_version=X` doesn't match what `mvn install` actually produced, the publisher silently picks up **stale jars** from a previous build. Your code changes will appear to have no effect.

**How it happens:**
- FHIR Core's `pom.xml` declares its version (e.g. `6.8.1`)
- `mvn install` writes jars to `~/.m2/repository/.../6.8.1/`
- If `rebuild.sh` passes `-Dcore_version=6.8.2-SNAPSHOT` to the publisher, it resolves to **old** jars at `~/.m2/repository/.../6.8.2-SNAPSHOT/` from a prior build
- The publisher compiles and runs fine — but with the wrong code

**How we prevent it:**
- `rebuild.sh` auto-detects the version from `org.hl7.fhir.core/pom.xml` using `mvn help:evaluate`
- After building the publisher, it checks that the core jar timestamp is consistent
- **Never hardcode `CORE_VERSION`** — always let it be auto-detected
- The publisher build deletes the CLI `target/` dir before `mvn clean package` to defeat shade plugin caching (see below)

**The shade plugin trap:**
Even with the correct version, `mvn clean package` may produce a fat JAR containing stale dependency classes. The maven-shade-plugin caches resolved dependencies in the `target/` directory. The only reliable fix is to delete `target/` before building. `rebuild.sh` does this automatically.

**If you suspect stale jars:**
```bash
# Check what version core actually produces
cd org.hl7.fhir.core && mvn help:evaluate -Dexpression=project.version -q -DforceStdout

# Verify a specific fix is in the fat JAR
cd /tmp && jar xf /path/to/publisher.jar org/hl7/fhir/utilities/xhtml/XhtmlParser.class
javap -p XhtmlParser.class | grep 'DEFINED_ENTITIES'  # should show static field if fix is present

# Check timestamps in maven repo
ls -la ~/.m2/repository/ca/uhn/hapi/fhir/org.hl7.fhir.utilities/*/org.hl7.fhir.utilities-*.jar

# Nuclear option: delete cached versions and rebuild
rm -rf ~/.m2/repository/ca/uhn/hapi/fhir/org.hl7.fhir.{utilities,r5,validation,convertors,r4}/
./rebuild.sh all
```

### Example: Proving a Change Propagated

This repo includes a sample change in FHIR Core that demonstrates the pipeline. In `org.hl7.fhir.core/org.hl7.fhir.utilities/.../Utilities.java`, the `describeDuration(Duration)` method has an added "seconds" tier:

```java
// BEFORE: durations < 2 min showed raw milliseconds ("44645 ms old")
// AFTER:  durations 2s–2min now show seconds ("33 secs old")
} else if (d.toSeconds() > 2) {
  return String.format("%s secs", d.toSeconds());
}
```

This appears in the IG Publisher startup banner:
```
FHIR IG Publisher Version 2.1.2-SNAPSHOT (...). Built ... (33 secs old)
                                                          ^^^^^^^^^^^
                                                    from FHIR Core change
```

## Repository Structure

```
igpublisher/
├── org.hl7.fhir.core/       ← submodule: FHIR Core library
├── fhir-ig-publisher/        ← submodule: IG Publisher
├── rebuild.sh                ← build orchestration script
└── README.md                 ← this file
```

## Notes

- **Kindling** (`HL7/kindling`) is a sibling project that also depends on FHIR Core, but the IG Publisher does **not** depend on Kindling. They are independent consumers of FHIR Core.
- The core version is auto-detected from `org.hl7.fhir.core/pom.xml`. Do not hardcode it.

---

## Performance Optimizations

We profiled the IG Publisher using JFR (Java Flight Recorder) against US Core 9.0.0 and implemented 11 targeted fixes across FHIR Core and the IG Publisher. All changes are backward-compatible and require no configuration.

### Results

**A/B benchmark: 3 runs each, same warm txcache, same IG, same machine:**

```
UPSTREAM:   4:04, 3:52, 3:47  (avg 3:54)
OPTIMIZED:  2:42, 2:39, 2:43  (avg 2:41)

Improvement: 31.2% faster — 73 seconds saved per build
```

Optimized runs also show much lower variance (4s range vs 17s), suggesting reduced GC pressure and cache thrashing.

### Phase-by-Phase Impact

| Phase | Upstream | Optimized | Change |
|-------|----------|-----------|--------|
| Check profiles & code systems | 26s | 15s | **-44%** |
| Previous Version Comparison | 58s | 41s | **-29%** |
| Generate Spreadsheets | 41s | 29s | **-28%** |
| Processing Provenance Records | 8s | 7s | -10% |

### What We Changed

**FHIR Core** (`org.hl7.fhir.core/`, 8 files):

| Fix | File | Problem → Solution |
|-----|------|---------------------|
| O(1) `drop()` | `CanonicalResourceManager.java` | O(n) map scan per drop → reverse index (`mapInverse`) for instant key lookup |
| O(n) `getList()` | `CanonicalResourceManager.java` | O(n²) `List.contains()` dedup → `IdentityHashMap`-backed Set for O(n) dedup |
| Cached comparator | `CanonicalResourceManager.java` | `new MetadataResourceVersionComparator<>()` on every `see()` call → single cached instance |
| Static type cache | `FHIRPathEngine.java` | Every `new FHIRPathEngine()` iterated all StructureDefinitions → static `WeakHashMap` cache keyed by context |
| Static collections | `XhtmlParser.java` | `elements`, `attributes`, `definedEntities` rebuilt per instance → `static final` initialized once |
| Cached resource names | `SimpleWorkerContext.java` | `getResourceNames()` rebuilt list every call → lazy-init `volatile` cache |
| SemverParser cache | `SemverParser.java` | `parseSemver()` re-parsed every call → `ConcurrentHashMap` result cache |
| Batched cache saves | `TerminologyCache.java` | **Entire cache file rewritten to disk on every terminology lookup** → mark dirty, flush every 5 seconds + shutdown hook |
| Static JsonFactory | `NpmPackageIndexBuilder.java` | New `JsonFactory` per use → shared static instance |

**IG Publisher** (`fhir-ig-publisher/`, 2 files):

| Fix | File | Problem → Solution |
|-----|------|---------------------|
| NamingSystem URL cache | `ValidationServices.java` | Linear scan of all NamingSystems per `resolveURL()` → pre-built `HashSet` lookup |
| Async usage stats | `PublisherGenerator.java` | Blocking HTTP call for usage stats → daemon thread |

### How We Found These

1. **JFR profiling** (`-XX:StartFlightRecording=settings=profile`) with 10ms sampling
2. Identified CPU hotspots by leaf-frame sample counts
3. Traced call chains to find the algorithmic root cause
4. Verified each fix with `javap -p` on classes extracted from the fat JAR

### Key Pitfalls Discovered

1. **TerminologyCache O(n²) I/O**: The single biggest find. On cold caches, `save(nc)` rewrites the entire cache file after every single terminology lookup. With thousands of lookups, this means writing files of size 1, 2, 3, ... N entries — classic O(n²). This dominated 88% of CPU on cold-cache runs and was invisible in warm-cache profiles.

2. **Parallelization is unsafe**: We attempted to parallelize `PreviousVersionComparator.startChecks()` but it hung due to deeply non-thread-safe internals: `BaseWorkerContext` has 20+ `synchronized(lock)` blocks, `FHIRPathEngine` uses a static synchronized `WeakHashMap`, and `FilesystemPackageCacheManager` has file-level contention. Reverted.

3. **Version mismatch trap**: See the section above — wrong `-Dcore_version` silently uses stale jars.

### Benchmarking

The `tmp/perf/ab-benchmark.sh` script runs a controlled A/B comparison:
- Restores txcache from a snapshot before each run (eliminates cache state variance)
- Runs each JAR N times (default 3) and reports per-run + average times
- Extracts key phase timings from logs

```bash
# Build both JARs, then:
./tmp/perf/ab-benchmark.sh 3   # 3 runs each, ~17 min total
```

See [JOURNAL.md](JOURNAL.md) for the full profiling history, raw data, and detailed analysis.
