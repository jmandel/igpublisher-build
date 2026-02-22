# FHIR IG Publisher: SQLite Batch Insert Performance Fix

**Branch:** [`perf/db-batch-inserts`](https://github.com/jmandel/fhir-ig-publisher/tree/perf/db-batch-inserts)  
**File changed:** `org.hl7.fhir.publisher.core/.../renderers/DBBuilder.java`  
**Impact:** htmlOutputs phase **83–94% faster**, total build **34% faster**

---

## What Was Slow

The `htmlOutputs` phase of the IG Publisher generates HTML fragments for every resource, then
writes ValueSet expansion codes and CodeSystem concept data into a SQLite database (`package.db`).
On the mCODE IG (469 resources, ~20K ValueSet codes, ~670 ConceptMap mappings), this phase took
**~100 seconds** — making it the longest single phase in the build.

Profiling revealed that only **~16 seconds** was spent on actual HTML rendering. The remaining
**~85 seconds** was spent writing to SQLite.

## The Underlying Cause

### 1. `recordExpansion()` — individual inserts with autocommit (84.7s)

During HTML generation, each ValueSet's expansion is written to the `ValueSet_Codes` table via
`recordExpansion()` → `addContains()`. The original code called `psql.executeUpdate()` for every
single code:

```java
// Original: one INSERT per code, autocommit on each
private void addContains(ValueSet vs, ValueSetExpansionContainsComponent e, 
                          PreparedStatement psql) throws SQLException {
    // ... set parameters ...
    psql.executeUpdate();   // ← fsync to disk on EVERY row
    for (ValueSetExpansionContainsComponent c : e.getContains()) {
        addContains(vs, c, psql);
    }
}
```

With SQLite's default journal mode, each `executeUpdate()` with autocommit triggers:
1. Begin transaction
2. Write to WAL/journal
3. **fsync to disk** (the expensive part — forces OS to flush write buffers)
4. Commit transaction

For ~20,000 codes, this produced ~20,000 fsyncs. On typical storage, each fsync takes 2–5ms,
totaling **40–100 seconds** of pure I/O wait.

Additionally, `recordExpansion()` was `synchronized`, meaning that during multi-threaded HTML
generation, all threads serialized on this single lock to write to the database one row at a time.

### 2. `finishResources()` — same pattern across 5 insert loops (3.5s)

The `finishResources()` method runs after resource loading and writes CodeSystem properties,
concepts, concept properties, designations, and ConceptMap mappings. Each of these 5 loops used
individual `executeUpdate()` calls without wrapping in a transaction:

```java
// Original: 5 separate loops, each doing individual autocommit inserts
for (CodeSystem cs : codesystems) {
    addConcepts(cs, cs.getConcept(), psql, 0);  // executeUpdate per concept
}
for (CodeSystem cs : codesystems) {
    addConceptProperties(cs, cs.getConcept(), psql);  // executeUpdate per property
}
// ... same for designations, mappings
```

### When It Happens

This affects **every IG build** that has `generatingDatabase: true` (the default when the
template supports it). The impact scales with:

- **Number of ValueSets** and their expansion sizes (each code = 1 INSERT)
- **Number of CodeSystems** and their concept counts (each concept = 1 INSERT, plus properties
  and designations)
- **Number of ConceptMaps** and their mapping entries

For IGs that reference large terminologies (SNOMED CT, LOINC, RxNorm), the impact can be even
more severe than the 85s seen with mCODE.

## The Fix

### Change 1: Deferred batch insert for ValueSet expansions

Instead of writing each expansion inline during parallel rendering, queue them for batch
processing after the parallel phase completes:

```java
public synchronized void recordExpansion(ValueSet vs, ValueSetExpansionOutcome exp) {
    // Queue for deferred execution — no DB write during parallel phase
    deferredExpansions.add(new DeferredExpansion(vs, exp));
}

public synchronized void flushDeferredOperations() throws SQLException {
    con.setAutoCommit(false);  // single transaction for all inserts
    PreparedStatement psql = con.prepareStatement("Insert into ValueSet_Codes ...");
    
    DeferredExpansion de;
    int batchCount = 0;
    while ((de = deferredExpansions.poll()) != null) {
        for (ValueSetExpansionContainsComponent e : ...) {
            // ... set parameters ...
            psql.addBatch();           // buffer in memory
            if (++batchCount % 5000 == 0) {
                psql.executeBatch();   // flush periodically to limit memory
            }
        }
    }
    psql.executeBatch();  // flush remaining
    con.commit();         // single fsync for all ~20K rows
}
```

This changes ~20,000 fsyncs into **1 fsync**.

### Change 2: Transaction wrapping for `finishResources()`

Wrap all 5 insert loops in a single transaction, and replace `executeUpdate()` with
`addBatch()` + `executeBatch()`:

```java
public void finishResources() {
    con.setAutoCommit(false);
    try {
        // Properties
        for (...) { psql.addBatch(); }
        psql.executeBatch();
        
        // Concepts
        for (...) { psql.addBatch(); }  // in addConcepts() recursive helper
        psql.executeBatch();
        
        // ... ConceptProperties, Designations, ConceptMappings same pattern ...
        
        con.commit();  // single fsync for everything
    } catch (SQLException e) {
        con.rollback();
        throw e;
    } finally {
        con.setAutoCommit(origAutoCommit);
    }
}
```

## Measurements

All measurements on mCODE IG, cold build (output directory cleared), 28GB heap, JDK 17.

### htmlOutputs phase

| Metric | Before | After (1 thread) | After (12 threads) |
|--------|--------|-------------------|---------------------|
| htmlOutputs wall time | 100.3s | **16.7s** | **5.8s** |
| DB flush time | 84.7s | 0.1s | 0.1s |
| DB cumulative time | 85.0s | 2.2s | 2.2s |
| Rendering (pool wall) | 16.5s | 16.5s | 5.6s |

### Overall build

| Metric | Before | After (12 threads) | Change |
|--------|--------|---------------------|--------|
| Total wall time | 282s | **186s** | **−34%** |
| htmlOutputs | 100.3s | 5.8s | −94% |
| Other phases | 182s | 180s | ~same |

### Multi-thread scaling (now actually works)

| Threads | Before | After |
|---------|--------|-------|
| 1 | 103s | 16.7s |
| 12 | 94s (+9%) | 5.8s (+188%) |

Before the fix, adding threads only improved the rendering portion (~16s) but the 85s DB
flush dominated total time, masking the parallelism benefit. After the fix, multi-threading
achieves the expected ~3× speedup on the rendering work.

### Output correctness

Verified by comparing `package.db` table row counts between before/after builds — all identical:
- Resources: 350
- ConceptMappings: 673
- ValueSet_Codes: 19,932
- (Plus 12 other tables, all matching)

HTML output diff shows only expected non-deterministic differences (UUIDs, xlsx timestamps).

## Why Wasn't This Caught Earlier?

1. **The profiler blamed rendering**: CPU profiling tools (JFR, async-profiler) attributed time
   to HTML rendering methods because `recordExpansion()` was called inline from the rendering
   code path. The I/O wait during fsync doesn't show up as CPU time — it appears as blocked/idle
   time that's easy to miss.

2. **The DB timing was aggregated**: The publisher reports "DB Cumulative Time" at the end of
   the build, but doesn't break it down by phase. The 85s was hidden inside the htmlOutputs
   phase timing rather than being called out separately.

3. **Single-thread testing masks the issue**: With 1 thread, the DB writes happen inline with
   rendering, so the total time looks like "rendering is slow" rather than "DB writes are slow".

## Finding Similar Issues

The root cause here — **autocommitted SQLite writes in tight loops** — is a pattern that can
hide in any codebase that uses JDBC with SQLite. Here's how to systematically find them:

### Pattern 1: `executeUpdate()` or `execute()` inside loops

Search for `executeUpdate()` calls where the PreparedStatement is reused in a loop without
`setAutoCommit(false)`. Each call is a separate transaction + fsync.

```bash
# Find executeUpdate/execute inside Java files
grep -rn 'executeUpdate\|\.execute(' --include='*.java' | grep -v test | grep -v '/target/'
```

Then manually verify: is the call inside a for/while loop? Is there a surrounding
`setAutoCommit(false)`?

**Known remaining instances in this codebase:**
- `DBBuilder.addToCSList()` / `addToVSList()` — `sql.execute()` per OID, per system, per source,
  per ref (6+ loops). Called per CodeSystem/ValueSet during summaries phase.
- `OidIndexBuilder.java` — `psql.execute()` per OID per resource file. Called during package
  loading. Can be thousands of files.
- `StorageSqlite3.java` (r4 + r5) — `p.execute()` per result row in SQL-on-FHIR. Called when
  SQL views are enabled.
- `XIGDatabaseBuilder.java` — `psql.executeUpdate()` per realm/authority in `finish()`. Lower
  iteration count.

### Pattern 2: `synchronized` methods that do I/O

Any `synchronized` method that writes to disk/network serializes all threads on that I/O
operation. This defeats multi-threading even if the calling code is parallel.

```bash
grep -rn 'synchronized.*void\|synchronized.*int\|synchronized.*String' --include='*.java' \
  | grep -v test | grep -v '/target/'
```

Then check: does the method body do file writes, DB writes, or network calls?

**Known instances:**
- `PublisherGenerator.addFileToNpm()` — synchronized + tar/gzip writes. Called from parallel
  HTML generation for every output file.
- The now-fixed `recordExpansion()` was synchronized + DB writes.

### Pattern 3: Wall time vs CPU time divergence

When profiling, if a phase's wall time is much larger than the CPU time attributed to it,
the gap is I/O wait, lock contention, or GC pauses. The technique that found this bug:

1. Add `System.nanoTime()` wall-clock timers around the outer phase
2. Add `AtomicLong` accumulators around each sub-operation inside the phase
3. Sum the sub-operations — the **unaccounted gap** is where the real bottleneck hides
4. If the gap is large, add timers to the gaps (between sub-operations, in framework code,
   in infrastructure like DB flush) until you find it

In our case: htmlOutputs = 100s, but all sub-operations summed to 16s. The 84s gap was
`db.flushDeferredOperations()` — a single line of infrastructure code that nobody thought
to measure.

### Pattern 4: Phase-level timing instrumentation

Add phase markers to any long-running build step:

```java
long t0 = System.nanoTime();
expensiveOperation();
logMessage(String.format("  operation took %.1fs", (System.nanoTime() - t0) / 1e9));
```

For parallel phases, use `AtomicLong` to accumulate CPU time across threads, then compare
to wall clock. A large ratio of CPU:wall means contention; a small ratio means I/O wait.

## How to Reproduce

```bash
# Clone the fix branch
git clone https://github.com/jmandel/fhir-ig-publisher.git
cd fhir-ig-publisher
git checkout perf/db-batch-inserts

# Build
mvn clean package -DskipTests -Dmaven.javadoc.skip=true

# Run on any IG with ValueSets
java -Xmx28g -Dig.threads=1 -jar org.hl7.fhir.publisher.cli/target/*.jar -ig /path/to/ig
```

Compare the "DB Cumulative Time" line at the end of the build log, and the wall time between
`@@PHASE_START htmlOutputs` and `@@PHASE_END htmlOutputs`.
