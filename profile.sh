#!/bin/bash
# profile.sh — Fast profiling of IG Publisher phases
#
# Usage:
#   ./profile.sh run  <ig> [--threads N] [--bench PHASE --repeat N]
#   ./profile.sh flame <jfr-or-collapsed-file>
#   ./profile.sh compare <dir1> <dir2>
#   ./profile.sh baseline <ig>
#
# IGs: mcode, uscore
# Phases: htmlOutputs, spreadsheets
#
# Examples:
#   ./profile.sh run mcode                          # Full build, extract phase timings
#   ./profile.sh run mcode --threads 4              # Full build with 4 HTML threads
#   ./profile.sh run mcode --bench htmlOutputs --repeat 3  # Benchmark HTML phase 3x
#   ./profile.sh baseline mcode                     # Save output as baseline for diffing
#   ./profile.sh compare tmp/baseline-mcode tmp/test-mcode/output  # Diff outputs

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
JAVA_HOME="$HOME/tools/jdk-17.0.18+8"
MAVEN_HOME="$HOME/tools/apache-maven-3.9.12"
ASPROF="/tmp/async-profiler-3.0-linux-arm64/lib/libasyncProfiler.so"
PUBLISHER_JAR="$SCRIPT_DIR/fhir-ig-publisher/org.hl7.fhir.publisher.cli/target/org.hl7.fhir.publisher.cli-2.1.2-SNAPSHOT.jar"
RESULTS_DIR="$SCRIPT_DIR/tmp/perf"
export PATH="$HOME/.local/share/gem/ruby/3.2.0/bin:$JAVA_HOME/bin:$MAVEN_HOME/bin:$PATH"

resolve_ig() {
  case "$1" in
    mcode) echo "$SCRIPT_DIR/tmp/test-mcode" ;;
    uscore) echo "$SCRIPT_DIR/tmp/test-uscore" ;;
    *) echo "$1" ;;  # Assume path
  esac
}

cmd_run() {
  local ig_name="${1:?Usage: profile.sh run <ig>}"
  shift
  local ig_dir
  ig_dir=$(resolve_ig "$ig_name")
  local threads="" bench_phase="" bench_repeat=""
  local extra_jvm_args=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --threads) threads="$2"; shift 2 ;;
      --bench)   bench_phase="$2"; shift 2 ;;
      --repeat)  bench_repeat="$2"; shift 2 ;;
      *) echo "Unknown arg: $1"; exit 1 ;;
    esac
  done

  [[ -n "$threads" ]] && extra_jvm_args+=("-Dig.threads=$threads")
  [[ -n "$bench_phase" ]] && extra_jvm_args+=("-Dig.benchmark.phase=$bench_phase")
  [[ -n "$bench_repeat" ]] && extra_jvm_args+=("-Dig.benchmark.repeat=${bench_repeat:-3}")

  # Prep
  mkdir -p "$RESULTS_DIR"
  cd "$ig_dir"
  rm -rf output fsh-generated/includes 2>/dev/null || true

  # Run sushi if needed
  if [[ -f sushi-config.yaml ]]; then
    echo "=== Running sushi ==="
    sushi . 2>&1 | tail -3
  fi

  # Restore txcache for uscore
  if [[ "$ig_name" == "uscore" && -d "$SCRIPT_DIR/tmp/perf/txcache-snapshot" ]]; then
    rm -rf txCache
    cp -r "$SCRIPT_DIR/tmp/perf/txcache-snapshot" txCache
  fi

  local ts
  ts=$(date +%Y%m%d-%H%M%S)
  local log_file="$RESULTS_DIR/run-${ig_name}-${ts}.log"
  local flame_file="$RESULTS_DIR/flame-${ig_name}-${ts}.html"
  local jfr_file="$RESULTS_DIR/profile-${ig_name}-${ts}.jfr"

  echo "=== Running IG Publisher ==="
  echo "  IG: $ig_dir"
  echo "  Threads: ${threads:-auto}"
  echo "  Benchmark: ${bench_phase:-none} x${bench_repeat:-0}"
  echo "  Log: $log_file"
  echo "  Flame: $flame_file"

  # Build JVM args
  local jvm_args=(
    -Xmx28g
    "${extra_jvm_args[@]}"
  )

  # Use async-profiler if available
  if [[ -f "$ASPROF" ]]; then
    jvm_args+=("-agentpath:${ASPROF}=start,event=cpu,file=${flame_file},flamegraph")
  else
    # Fallback to JFR
    jvm_args+=("-XX:StartFlightRecording=settings=profile,filename=${jfr_file},dumponexit=true")
  fi

  # Run
  local start_time=$SECONDS
  "$JAVA_HOME/bin/java" "${jvm_args[@]}" \
    -jar "$PUBLISHER_JAR" -ig . -no-sushi 2>&1 | tee "$log_file"
  local elapsed=$(( SECONDS - start_time ))

  echo ""
  echo "=== Results ==="
  echo "  Total wall time: ${elapsed}s"
  echo ""

  # Extract phase timings
  echo "  Phase Timings:"
  grep '@@PHASE_\|@@BENCH_' "$log_file" | while read -r line; do
    echo "    $line"
  done

  echo ""
  echo "  Publisher Timings:"
  grep 'Built\. Times:' "$log_file" || true
  echo ""
  grep 'Errors:.*Warnings:' "$log_file" || true

  if [[ -f "$flame_file" ]]; then
    echo ""
    echo "  Flame graph: $flame_file"
  fi
  echo "  Full log: $log_file"
}

cmd_baseline() {
  local ig_name="${1:?Usage: profile.sh baseline <ig>}"
  local ig_dir
  ig_dir=$(resolve_ig "$ig_name")
  local baseline_dir="$SCRIPT_DIR/tmp/baseline-${ig_name}"

  if [[ ! -d "$ig_dir/output" ]]; then
    echo "No output/ in $ig_dir — run 'profile.sh run $ig_name' first"
    exit 1
  fi

  echo "Saving baseline from $ig_dir/output → $baseline_dir"
  rm -rf "$baseline_dir"
  cp -r "$ig_dir/output" "$baseline_dir"

  # Save a manifest
  find "$baseline_dir" -type f | sort | while read -r f; do
    md5sum "$f"
  done > "$baseline_dir.manifest"

  echo "Saved $(wc -l < "$baseline_dir.manifest") files"
}

cmd_compare() {
  local dir1="${1:?Usage: profile.sh compare <dir1> <dir2>}"
  local dir2="${2:?}"

  echo "=== Comparing outputs ==="
  echo "  A: $dir1"
  echo "  B: $dir2"
  echo ""

  # File inventory diff
  local files_a files_b
  files_a=$(cd "$dir1" && find . -type f | sort)
  files_b=$(cd "$dir2" && find . -type f | sort)

  local only_a only_b
  only_a=$(comm -23 <(echo "$files_a") <(echo "$files_b") | wc -l)
  only_b=$(comm -13 <(echo "$files_a") <(echo "$files_b") | wc -l)
  local common
  common=$(comm -12 <(echo "$files_a") <(echo "$files_b") | wc -l)

  echo "  Files only in A: $only_a"
  echo "  Files only in B: $only_b"
  echo "  Common files: $common"

  if [[ "$only_a" -gt 0 ]]; then
    echo ""
    echo "  Files only in A (first 20):"
    comm -23 <(echo "$files_a") <(echo "$files_b") | head -20 | sed 's/^/    /'
  fi
  if [[ "$only_b" -gt 0 ]]; then
    echo ""
    echo "  Files only in B (first 20):"
    comm -13 <(echo "$files_a") <(echo "$files_b") | head -20 | sed 's/^/    /'
  fi

  # Content diff (skip timestamps, dates, UUIDs)
  echo ""
  echo "  Content diffs (ignoring timestamps):"
  local diff_count=0
  local checked=0
  while IFS= read -r f; do
    checked=$((checked + 1))
    local fa="$dir1/$f"
    local fb="$dir2/$f"
    # Skip binary files
    if file "$fa" | grep -q "image\|gzip\|Zip\|Excel\|SQLite"; then
      # Binary compare
      if ! cmp -s "$fa" "$fb"; then
        diff_count=$((diff_count + 1))
        if [[ $diff_count -le 20 ]]; then
          echo "    BINARY DIFF: $f ($(wc -c < "$fa") vs $(wc -c < "$fb") bytes)"
        fi
      fi
      continue
    fi
    # Text compare with timestamp filtering
    if ! diff -q \
      <(sed -E 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.Z+-]+/TIMESTAMP/g; s/[0-9]{1,2}\/[0-9]{1,2}\/[0-9]{2,4}[, ]+[0-9]{1,2}:[0-9]{2} [AP]M/TIMESTAMP/g; s/[a-f0-9-]{36}/UUID/g' "$fa") \
      <(sed -E 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.Z+-]+/TIMESTAMP/g; s/[0-9]{1,2}\/[0-9]{1,2}\/[0-9]{2,4}[, ]+[0-9]{1,2}:[0-9]{2} [AP]M/TIMESTAMP/g; s/[a-f0-9-]{36}/UUID/g' "$fb") \
      >/dev/null 2>&1; then
      diff_count=$((diff_count + 1))
      if [[ $diff_count -le 20 ]]; then
        echo "    DIFF: $f"
        diff --unified=1 \
          <(sed -E 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.Z+-]+/TIMESTAMP/g; s/[0-9]{1,2}\/[0-9]{1,2}\/[0-9]{2,4}[, ]+[0-9]{1,2}:[0-9]{2} [AP]M/TIMESTAMP/g; s/[a-f0-9-]{36}/UUID/g' "$fa") \
          <(sed -E 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.Z+-]+/TIMESTAMP/g; s/[0-9]{1,2}\/[0-9]{1,2}\/[0-9]{2,4}[, ]+[0-9]{1,2}:[0-9]{2} [AP]M/TIMESTAMP/g; s/[a-f0-9-]{36}/UUID/g' "$fb") \
          2>/dev/null | head -10 | sed 's/^/      /'
      fi
    fi
  done < <(comm -12 <(echo "$files_a") <(echo "$files_b"))

  echo ""
  echo "  Checked: $checked files, $diff_count diffs found"

  # qa.json comparison
  if [[ -f "$dir1/qa.json" && -f "$dir2/qa.json" ]]; then
    echo ""
    echo "  QA comparison:"
    echo -n "    A: "; python3 -c "import json; d=json.load(open('$dir1/qa.json')); print(f'Errors={d.get(\"errs\")}, Warnings={d.get(\"warnings\")}')" 2>/dev/null || echo "(parse error)"
    echo -n "    B: "; python3 -c "import json; d=json.load(open('$dir2/qa.json')); print(f'Errors={d.get(\"errs\")}, Warnings={d.get(\"warnings\")}')" 2>/dev/null || echo "(parse error)"
  fi
}

cmd_interactive() {
  local ig_name="${1:?Usage: profile.sh interactive <ig> [--debug]}"
  shift
  local ig_dir debug_mode=""
  ig_dir=$(resolve_ig "$ig_name")

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --debug) debug_mode=1; shift ;;
      *) echo "Unknown arg: $1"; exit 1 ;;
    esac
  done

  # Prep
  cd "$ig_dir"
  rm -rf output fsh-generated/includes 2>/dev/null || true
  if [[ -f sushi-config.yaml ]]; then
    echo "=== Running sushi ==="
    sushi . 2>&1 | tail -3
  fi
  if [[ "$ig_name" == "uscore" && -d "$RESULTS_DIR/txcache-snapshot" ]]; then
    rm -rf txCache && cp -r "$RESULTS_DIR/txcache-snapshot" txCache
  fi

  local extra_jvm_args=()
  if [[ -n "$debug_mode" ]]; then
    extra_jvm_args+=("-agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=*:5005")
    echo "=== JDWP debug agent enabled on port 5005 ==="
    echo "Hot-swap workflow:"
    echo "  1. Edit a .java file in org.hl7.fhir.core or publisher"
    echo "  2. javac -cp <classpath> YourFile.java"
    echo "  3. Use jdb -connect com.sun.jdi.SocketAttach:hostname=localhost,port=5005"
    echo "     then: redefine com.example.MyClass /path/to/MyClass.class"
    echo "  4. Re-run the phase in this REPL — change is live without restart"
    echo ""
  fi

  echo "=== Starting IG Publisher in interactive mode ==="
  echo "Publisher will do a full build first, then wait for commands."
  echo ""
  echo "REPL commands:"
  echo "  htmlOutputs [threads=N] [files=N] [filter=pattern]"
  echo "  spreadsheets [files=N] [filter=pattern]"
  echo "  quit"
  echo ""
  echo "Examples:"
  echo "  htmlOutputs files=10              # First 10 files (~2s)"
  echo "  htmlOutputs filter=StructureDefinition  # Only SDs"
  echo "  htmlOutputs threads=1 files=1     # Single file, single thread"
  echo ""
  echo "To profile a re-run, use async-profiler in another terminal:"
  echo "  asprof start -e cpu <PID>"
  echo "  # ... type a command in this terminal ..."
  echo "  asprof stop -o flamegraph -f /tmp/flame.html <PID>"
  echo ""

  local logfile="/tmp/ig-interactive.log"

  "$JAVA_HOME/bin/java" -Xmx28g -Dig.interactive=true \
    "${extra_jvm_args[@]}" \
    -jar "$PUBLISHER_JAR" -ig . -no-sushi 2>&1 | tee "$logfile"
}

# Main dispatch
case "${1:-help}" in
  run)         shift; cmd_run "$@" ;;
  baseline)    shift; cmd_baseline "$@" ;;
  compare)     shift; cmd_compare "$@" ;;
  interactive) shift; cmd_interactive "$@" ;;
  *)
    echo "Usage: profile.sh <command> [args]"
    echo ""
    echo "Commands:"
    echo "  run <ig> [--threads N]"
    echo "    Full build with async-profiler flame graph + phase timings."
    echo ""
    echo "  interactive <ig>"
    echo "    Full build, then REPL to re-run phases in a hot JVM (~2min/iter)."
    echo "    Attach async-profiler from another terminal for targeted profiling."
    echo ""
    echo "  baseline <ig>"
    echo "    Save current output/ as baseline for comparison."
    echo ""
    echo "  compare <dir1> <dir2>"
    echo "    Compare two output directories for correctness."
    echo ""
    echo "IGs: mcode, uscore (or a path)"
    echo "Phases: htmlOutputs, spreadsheets"
    ;;
esac
