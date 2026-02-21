# FHIR IG Publisher — Performance Optimization Journal

## Project Setup
- Repo: https://github.com/jmandel/igpublisher-build
- FHIR Core fork: https://github.com/jmandel/org.hl7.fhir.core (branch: describe-duration-secs)
- Build: `./rebuild.sh all` (core → publisher, ~5 min)
- Test IG: US Core (`/tmp/test-uscore`), ~4 min cached run with 28GB heap

## Profiling Methodology
- **JFR** (Java Flight Recorder) with `settings=profile` (10ms sampling interval)
- Built-in publisher phase timing (wall clock between `log()` calls)
- 12,386 CPU samples over 247s run

---

## Profiling Run: US Core (cached, 28GB heap, ~4:07 wall clock)

### Phase Timing Breakdown
| Phase | Duration | Cumulative | Mem | Notes |
|-------|----------|-----------|-----|-------|
| Initialization (load packages) | 15.3s | 00:15 | 1GB | Loading ~9,400 JSON resources from 5+ packages |
| Process Loaded Resources | 5.4s | 00:21 | 1GB | |
| Generating Snapshots | 2.2s | 00:23 | 1GB | |
| Fetch package-list.json (3x) | 2.5s | 00:26 | 1GB | Network: us/core, uv/ipa, uv/ips |
| Validating Conformance | 4.4s | 00:30 | 1GB | |
| **Check profiles & code systems** | **30.2s** | **01:01** | **3GB** | Major bottleneck |
| **Previous Version Comparison** | **76.1s** | **02:17** | **12GB** | Loads ALL historical US Core releases |
| Validating Resources | 9.1s | 02:26 | 14GB | |
| **Run Template** | **31.8s** | **02:58** | 9GB | Jekyll template processing |
| Generate HTML Outputs | 2.1s | 03:00 | 9GB | |
| **Generate Spreadsheets** | **43.9s** | **03:44** | 9GB | Per-SD Excel generation, surprisingly slow |
| Generate Summaries | 4.6s | 03:48 | 5GB | |
| Summary Outputs | 17.7s | 04:06 | 10GB | |
| Usage stats + cleanup | 1.1s | 04:07 | 5GB | |

### Top CPU Hotspots (leaf method samples)
| Rank | Method | Samples | % | Root Cause |
|------|--------|---------|---|------------|
| 1 | `ArrayList.indexOfRange()` | 4,191 | 34% | Called from `CanonicalResourceManager.getList()` which uses `List.contains()` for dedup — O(n²) on ~9,400 items |
| 2 | `HashMap$HashIterator.nextNode()` | 796 | 6% | General iteration overhead |
| 3 | `StringLatin1.charAt()` | 527 | 4% | String processing in parsers |
| 4 | `LinkedTreeMap.find()` (Gson) | 418 | 3% | JSON parsing |
| 5 | `JsonParser.parseType()` | 318 | 3% | R4 JSON deserialization |

### Top CPU Hotspots (inclusive / call tree)
| Rank | Method | Samples | % | Analysis |
|------|--------|---------|---|----------|
| 1 | `CanonicalResourceManager.getList()` | 4,288 | 35% | O(n²) dedup, called repeatedly by fetchResourcesByType |
| 2 | `BaseWorkerContext.fetchResourcesByType()` | 4,282 | 35% | Wrapper calling getList() — called from FHIRPathEngine constructor |
| 3 | `FHIRPathEngine.<init>()` | 2,254 | 18% | **Created per-resource** in ParserBase constructor; each one calls fetchResourcesByType(StructureDefinition.class) |
| 4 | `ParserBase.<init>()` | 1,377 | 11% | Creates new FHIRPathEngine → new ProfileUtilities every time |
| 5 | `XhtmlParser.<init>()` | 463 | 4% | Populates 2,125 entity map entries per instance |
| 6 | `XhtmlParser.defineEntities()` | 451 | 4% | (same — called from constructor) |
| 7 | `CanonicalResourceManager.drop()` | 438 | 4% | Already partially fixed with reverse index |
| 8 | `SimpleWorkerContext.getResourceNames()` | 385 | 3% | Iterates all structures, sorts, on every call |
| 9 | `RenderingContext.getProfileUtilities()` | 571 | 5% | Lazy-inits ProfileUtilities (creates FHIRPathEngine) |

### Top Allocation Hotspots
| Rank | Method | Alloc Samples | Notes |
|------|--------|--------------|-------|
| 1 | `TerminologyCache.loadNamedCache()` | 3,001 | Loading tx cache from disk |
| 2 | `Utilities.isWhitespace()` | 1,775 | Boxing int values? |
| 3 | `Utilities.escapeJson()` | 1,598 | String building |
| 4 | `XhtmlParser.peekChar()` | 1,388 | Char boxing |
| 5 | `JsonCreatorDirect.value()` | 1,160 | JSON output |

---

## Optimization Fixes Implemented

### Fix 1: `CanonicalResourceManager.getList()` — O(n²) → O(n) ✅
**File**: `org.hl7.fhir.r5/src/main/java/.../CanonicalResourceManager.java:909`
**Problem**: Uses `ArrayList.contains()` for dedup — linear scan per element = O(n²). With ~9,400 StructureDefinitions, this is catastrophic when called repeatedly.
**Fix**: Replace with `IdentityHashMap`-backed Set for O(1) identity-based dedup.
**Impact estimate**: 4,191 samples (34% of CPU) — should eliminate most of this.

### Fix 2: Cache FHIRPathEngine type data ✅
**File**: `org.hl7.fhir.r5/src/main/java/.../FHIRPathEngine.java:224`
**Problem**: Every `new FHIRPathEngine(context)` calls `fetchResourcesByType(StructureDefinition.class)` → `getList()` → iterates all ~9,400 structures to build allTypes/primitiveTypes maps. This happens per resource parsed because `ParserBase(context)` creates a new FHIRPathEngine.
**Fix**: Static `WeakHashMap<IWorkerContext, TypeDataCache>` so type data is computed once per context, then reused for all subsequent FHIRPathEngine instances.
**Impact estimate**: 2,254 samples (18%) — second-biggest hotspot. Eliminates redundant fetchResourcesByType calls.

### Fix 3: Make XhtmlParser entities/elements/attributes static ✅
**File**: `org.hl7.fhir.utilities/src/main/java/.../XhtmlParser.java:166-293`
**Problem**: Constructor populates 3 collections (2,125 entity entries, ~40 elements, ~40 attributes) from scratch on every `new XhtmlParser()`. These are constant data.
**Fix**: Move all three to `static final` fields initialized in a static block. Constructor becomes trivial.
**Impact estimate**: 463+451 samples (7%) — also reduces GC pressure from thousands of short-lived HashMap instances.

### Fix 4: Cache `SimpleWorkerContext.getResourceNames()` (planned)
**File**: `org.hl7.fhir.r5/src/main/java/.../SimpleWorkerContext.java:750`
**Problem**: Iterates all structures, filters, sorts on every call. Called 385 times in profiling.
**Fix**: Cache the sorted result, invalidate when structures change.
**Impact estimate**: 385 samples (3%)

### Prior fixes (from minimal IG profiling round):
- **Fix A**: `CanonicalResourceManager.drop()` O(n²) → O(1) with reverse index (`mapInverse`)
- **Fix B**: Static `JsonFactory` in `NpmPackageIndexBuilder`
- **Fix C**: Async usage stats in `PublisherGenerator.sendToServer()`
- Combined: 14.9s → 13.2s on minimal IG (-11%)

---

## ⚠️ CRITICAL LESSON: Version Mismatch Trap

**The first "optimized" benchmark showed zero improvement because the fixes weren't in the JAR.**

### What happened
- FHIR Core's `pom.xml` declares version `6.8.1` (our branch is based on the 6.8.1 tag)
- `mvn install` writes jars to `~/.m2/repository/.../6.8.1/`
- But `rebuild.sh` had `CORE_VERSION="6.8.2-SNAPSHOT"` hardcoded
- The publisher built with `-Dcore_version=6.8.2-SNAPSHOT`, resolving to **stale** jars from a prior build session
- Result: all 4 new fixes were compiled correctly but never made it into the publisher JAR
- The "optimized" run was actually running the **same code** as baseline

### How to prevent
- `rebuild.sh` now **auto-detects** the version from `org.hl7.fhir.core/pom.xml`
- After building, it verifies jar timestamps are consistent
- **Never hardcode CORE_VERSION** — see README.md "Version Mismatch Trap" section
- **The shade plugin caches aggressively** — even with `mvn clean package` and the correct version, the fat JAR may contain stale classes. Use `rm -rf target && mvn clean package` when rebuilding the publisher after core changes.
- To verify: `javap -p` on the class inside the fat JAR should show your changes
  ```bash
  cd /tmp && jar xf /path/to/publisher.jar org/hl7/fhir/utilities/xhtml/XhtmlParser.class
  javap -p XhtmlParser.class | grep 'DEFINED_ENTITIES'  # should show static field
  ```

---

## Benchmark: Runs 8 & 9 (INVALIDATED)

**Run 8**: Wrong `-Dcore_version` (6.8.2-SNAPSHOT vs 6.8.1). Stale jars from prior build.
**Run 9**: Correct version but shade plugin cached old fat JAR. Fixed with `rm -rf target`.
Both runs showed identical profile to baseline, confirming no fixes were active.

**Run 10**: Verified via `javap` that fat JAR contains `static final ELEMENTS`, `WeakHashMap typeDataCache`, etc. This is the real test.

---

## Benchmark: Run 10 (VERIFIED — correct code in JAR)

### Phase Timing Comparison
| Phase | Baseline | Optimized | Delta |
|-------|----------|-----------|-------|
| Initialization | 15.3s | 15.0s | -2% |
| **Process Loaded Resources** | **5.4s** | **1.0s** | **-82%** |
| **Generating Snapshots** | **2.2s** | **1.3s** | **-42%** |
| **Validating Conformance** | **4.4s** | **2.7s** | **-40%** |
| **Check profiles & code systems** | **30.2s** | **22.1s** | **-27%** |
| **Previous Version Comparison** | **76.1s** | **50.2s** | **-34%** |
| Validating Resources | 9.1s | 9.0s | ~same |
| **Run Template** | **31.8s** | **25.9s** | **-19%** |
| **Generate Spreadsheets** | **43.9s** | **32.2s** | **-27%** |
| Generate Summaries | 4.6s | 4.8s | ~same |
| Summary Outputs | 17.7s | 17.3s | ~same |
| **Total** | **4:07** | **3:06** | **-25% (61s saved)** |

### CPU Profile Comparison
| Metric | Baseline | Optimized | Change |
|--------|----------|-----------|--------|
| Total CPU samples | 12,386 | 6,309 | **-49%** |
| GC events | 108 | 107 | ~same |

### Hotspot Elimination
| Hotspot | Baseline samples | Optimized samples | Fix |
|---------|-----------------|-------------------|-----|
| `ArrayList.indexOfRange` (getList O(n²)) | 4,191 (34%) | **gone** | IdentityHashMap dedup |
| `FHIRPathEngine.<init>` | 2,254 (18%) | **gone from top 20** | WeakHashMap type cache |
| `XhtmlParser.defineEntities` | 451 (4%) | **gone** | Static entity table |
| `getResourceNames` | 385 (3%) | **gone** | Lazy-init cache |
| `getList()` inclusive | 4,288 | 308 | **-93%** |
| `fetchResourcesByType` inclusive | 4,282 | 304 | **-93%** |

### New Top Hotspots (what's left to optimize)
1. `StringBuilder.append(char)` — 944 samples — string building in parsers/renderers
2. `LinkedTreeMap.find` (Gson) — 417 — JSON parsing
3. `HashMap.nextNode` — 406 — general iteration
4. `XhtmlParser.parseAttributes` — 690 inclusive — XHTML parsing (inherent work)
5. `JsonTrackingParser` — ~350 inclusive — JSON parsing (inherent work)
6. `CanonicalResourceManager.see()` — 306 inclusive — resource registration

The remaining hotspots are **inherent work** (parsing, string ops) rather than algorithmic inefficiency. Further gains would require architectural changes (parallelization, caching parsed results).

---

## Observations & Future Investigation Targets

### Memory
- US Core needs **~14GB peak** during Previous Version Comparison (loads all historical releases)
- 108 GC events in 247s run — seems acceptable but high
- Peak heap usage: 11GB used / 17.8GB total

### Previous Version Comparison (76.1s, biggest wall-clock phase)
- Loads every historical US Core release to compare resources across versions
- This is the biggest phase but unclear if CPU or I/O bound
- Could be parallelized or made optional (there IS a `version-comparison: n/a` IG parameter to skip it)
- Each historical version creates its own context → more FHIRPathEngine constructions

### Generate Spreadsheets (43.9s, surprisingly expensive)
- Creates 2 Excel files per StructureDefinition (individual + aggregate)
- For US Core (~200 profiles) = 400+ Excel generations
- Apache POI overhead for each workbook
- Potential fix: parallelize, or defer aggregate spreadsheet to end

### Run Template (31.8s)
- Jekyll template processing — likely I/O bound (writing files)
- Would need strace/inotifywait to understand filesystem pattern

### Check profiles & code systems (30.2s)
- Validation of conformance resources against terminology
- May involve tx server calls (blocking network)
- Worth profiling in detail

### Potential high-impact future optimizations
1. **Parallelize independent phases** (snapshots, validation, comparison could overlap)
2. **Lazy-load historical versions** in comparison (don't load all at once)
3. **Cache ProfileUtilities/FHIRPathEngine at the context level** (not just type data — cache the whole engine)
4. **Reduce parser construction** — `ParserBase(context)` path creates heavy objects; callers should reuse

---

## Round 3: TerminologyCache + SemverParser + Comparator Caching

### New Fixes Implemented

#### Fix 6: SemverParser Result Cache (SemverParser.java)
- Added `ConcurrentHashMap<String, ParseResult> PARSE_CACHE` static field
- Cached results of `parseSemver(String)` and `parseSemver(String, boolean, boolean)`
- Hot caller: `VersionUtilities.isSemVer()` from CanonicalResourceManager version comparison
- 113 CPU samples in round 2 profile

#### Fix 7: Cached MetadataResourceVersionComparator (CanonicalResourceManager.java)
- Created single `versionComparator` field instead of `new MetadataResourceVersionComparator<>()` on every `see()` and `updateList()` call
- Eliminates object allocation per resource registration (thousands of resources)

#### Fix 8: Batch TerminologyCache Saves (TerminologyCache.java) — **BIGGEST FIND**
- **Root cause**: `save(nc)` rewrites entire cache file to disk on EVERY SINGLE terminology lookup
- Profile showed `Utilities.escapeJson` at 6,790/9,510 samples (71%!) — all from cache I/O
- `StreamEncoder.implWrite` at 1,644 samples (17%) — same root cause
- **Fix**: Mark caches dirty, flush only every 5 seconds + shutdown hook for final flush
- Estimated impact: **eliminate 88% of CPU time on cold-cache runs**

#### Fix 8b: Parallelize PreviousVersionComparator — REVERTED
- Attempted to parallelize `startChecks()` loop with ExecutorService
- Caused hang/deadlock due to:
  - Static `synchronized(typeDataCache)` in FHIRPathEngine (our WeakHashMap cache)
  - 20+ `synchronized(lock)` blocks in BaseWorkerContext
  - Shared `context.getTxClientManager().getMasterClient()` across threads
  - Filesystem-level contention in FilesystemPackageCacheManager
- **Lesson**: FHIR Core internals are deeply not thread-safe. Parallelization requires major refactoring.

### Thread-Safety Audit Findings
Key non-thread-safe components in FHIR Core:
1. `BaseWorkerContext` — 20+ `synchronized(lock)` blocks, all contexts share one lock object
2. `FHIRPathEngine.typeDataCache` — our static WeakHashMap with synchronized access creates a global serialization point
3. `FilesystemPackageCacheManager` — file-level locking on shared package cache
4. `TerminologyCache` — file I/O on every entry (now fixed with batching)

### Profile: Run 11 (5:21 partial, killed — cold txcache)
| Hotspot | Samples | % | Notes |
|---------|---------|---|-------|
| StringBuilder.append (escapeJson) | 4,031 | 42% | TerminologyCache.save writing JSON |
| StreamEncoder.implWrite | 1,644 | 17% | Disk I/O from cache writes |
| LinkedTreeMap.find (Gson) | 288 | 3% | JSON parsing |
| CachedCanonicalResource.getUrl | 254 | 3% | Resource lookups |
| JsonParser.parseType | 204 | 2% | R4 resource parsing |
| JsonTrackingParser.next | 182 | 2% | JSON lexing |
| TerminologyCache.save | 145 | 2% | Direct save overhead |

---

## A/B Benchmark: Final Results (US Core 9.0.0, warm cache, 3 runs each)

### Methodology
- Same IG (US Core 9.0.0), same txcache snapshot restored before every run
- Upstream: unmodified core (commit 0248e013a) + unmodified publisher (commit 4c46ff9e)
- Optimized: all perf fixes applied (8 files in core, 3 files in publisher)
- 28GB heap, JDK 17.0.18 Temurin, aarch64

### Raw Results
```
UPSTREAM:   4:04, 3:52, 3:47  (avg 3:54, range 17s)
OPTIMIZED:  2:42, 2:39, 2:43  (avg 2:41, range  4s)
```

### **Overall: 3:54 → 2:41 = 31.2% faster, 73s saved per build**

### Phase Breakdown (avg of 3 runs)
| Phase                        | Upstream | Optimized | Δ     |
|------------------------------|----------|-----------|-------|
| Check profiles & code systems| 26.2s    | 14.7s     | -44%  |
| Prev Version Comparison      | ~58s     | ~41s      | -29%  |
| Processing Provenance Records| 7.8s     | 7.0s      | -10%  |
| Generate Spreadsheets        | 40.8s    | 29.2s     | -28%  |
| Run Template                 | ~24s     | ~24s      |  0%   |

### Variance
- Optimized runs are far more consistent (4s range vs 17s range)
- This suggests upstream has more cache thrashing / GC pressure from allocations

### All Fixes Summary
| # | Fix | File(s) | Impact |
|---|-----|---------|--------|
| 1 | O(1) drop() via reverse index | CanonicalResourceManager.java | Eliminates O(n²) map scan |
| 2 | Static shared JsonFactory | NpmPackageIndexBuilder.java | Avoids factory construction |
| 3 | Async usage stats (daemon thread) | PublisherGenerator.java | Non-blocking stats |
| 4 | O(n) getList() via IdentityHashMap | CanonicalResourceManager.java | -93% samples |
| 5 | Static FHIRPathEngine type cache | FHIRPathEngine.java | Eliminates repeated allTypes iteration |
| 6 | Static XhtmlParser collections | XhtmlParser.java | Eliminates per-instance init |
| 7 | Cached getResourceNames() | SimpleWorkerContext.java | Lazy-init list |
| 8 | NamingSystem URL cache | ValidationServices.java | Set lookup vs iteration |
| 9 | SemverParser result cache | SemverParser.java | ConcurrentHashMap memoization |
| 10| Cached MetadataResourceVersionComparator | CanonicalResourceManager.java | Avoid alloc per see() |
| 11| **Batched TerminologyCache saves** | TerminologyCache.java | **5s flush window, not per-entry** |

### Lessons Learned
1. **Version mismatch trap**: core pom.xml version MUST match -Dcore_version or stale jars used
2. **Shade plugin trap**: must rm -rf target/ before publisher build or old fat JAR reused
3. **Always verify with javap**: extract class from fat JAR and check fields/methods present
4. **Parallelization is dangerous**: FHIR Core internals deeply non-thread-safe (BaseWorkerContext, FHIRPathEngine, FilesystemPackageCacheManager)
5. **Profile cold AND warm**: TerminologyCache.save() was invisible in warm runs but dominated cold runs
6. **O(n²) hides in plain sight**: getList() dedup, save-per-entry — both quadratic patterns
