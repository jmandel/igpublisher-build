#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────
# rebuild.sh — Build the FHIR IG Publisher with local FHIR Core
# ──────────────────────────────────────────────────────────────
#
# Usage:
#   ./rebuild.sh              Rebuild everything (core → publisher)
#   ./rebuild.sh core         Rebuild only FHIR Core
#   ./rebuild.sh publisher    Rebuild only IG Publisher
#   ./rebuild.sh run [args]   Run the built IG Publisher JAR

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Versions ─────────────────────────────────────────────────
# CORE_VERSION is auto-detected from org.hl7.fhir.core/pom.xml.
# This MUST match what mvn install produces, or the publisher
# will silently pick up stale JARs from ~/.m2/repository.
# See "Version Mismatch Trap" in README.md.
CORE_VERSION=$(cd "$BASE_DIR/org.hl7.fhir.core" && mvn help:evaluate -Dexpression=project.version -q -DforceStdout 2>/dev/null)
if [ -z "$CORE_VERSION" ]; then
  echo "ERROR: Could not detect FHIR Core version from pom.xml"
  echo "Falling back to grep..."
  CORE_VERSION=$(grep -m1 '<version>' "$BASE_DIR/org.hl7.fhir.core/pom.xml" | sed 's/.*<version>//;s/<.*//' | head -1)
fi
PUBLISHER_VERSION="2.1.2-SNAPSHOT"

# ── Java / Maven setup ──────────────────────────────────────
if [ -d "$HOME/tools/jdk-17.0.18+8" ]; then
  export JAVA_HOME="$HOME/tools/jdk-17.0.18+8"
fi
if [ -d "$HOME/tools/apache-maven-3.9.12" ]; then
  export PATH="$HOME/tools/apache-maven-3.9.12/bin:$PATH"
fi
export PATH="${JAVA_HOME:-/usr}/bin:$PATH"

MVN_OPTS="-DskipTests -Dmaven.javadoc.skip=true --batch-mode"
JAR="$BASE_DIR/fhir-ig-publisher/org.hl7.fhir.publisher.cli/target/org.hl7.fhir.publisher.cli-${PUBLISHER_VERSION}.jar"

# ── Build functions ──────────────────────────────────────────
build_core() {
  echo "=== Building FHIR Core (${CORE_VERSION}) ==="
  cd "$BASE_DIR/org.hl7.fhir.core"
  mvn install $MVN_OPTS
  echo ""
}

build_publisher() {
  echo "=== Building IG Publisher (core_version=${CORE_VERSION}) ==="
  cd "$BASE_DIR/fhir-ig-publisher"
  # Delete CLI target to defeat shade plugin caching of stale dependency classes
  rm -rf org.hl7.fhir.publisher.cli/target
  mvn clean package $MVN_OPTS -Dcore_version="$CORE_VERSION"
  echo ""
  echo "✓ Built: $JAR"

  # Verify the publisher JAR actually contains the locally-built core classes
  echo "=== Verifying core classes in publisher JAR ==="
  CORE_JAR="$HOME/.m2/repository/ca/uhn/hapi/fhir/org.hl7.fhir.utilities/${CORE_VERSION}/org.hl7.fhir.utilities-${CORE_VERSION}.jar"
  if [ -f "$CORE_JAR" ]; then
    CORE_TS=$(stat --format='%Y' "$CORE_JAR" 2>/dev/null || stat -f '%m' "$CORE_JAR" 2>/dev/null)
    PUB_TS=$(stat --format='%Y' "$JAR" 2>/dev/null || stat -f '%m' "$JAR" 2>/dev/null)
    if [ "$CORE_TS" -gt "$PUB_TS" ] 2>/dev/null; then
      echo "WARNING: Core JAR is newer than publisher JAR — this should not happen"
    else
      echo "✓ Core JAR ($CORE_VERSION) timestamp consistent with publisher JAR"
    fi
  else
    echo "WARNING: Core JAR not found at $CORE_JAR"
    echo "  The publisher may be using a different core version!"
    echo "  Check: grep '<version>' org.hl7.fhir.core/pom.xml"
  fi
}

# ── Dispatch ─────────────────────────────────────────────────
case "${1:-all}" in
  core)      build_core ;;
  publisher) build_publisher ;;
  all)       build_core && build_publisher ;;
  run)       shift; exec java -jar "$JAR" "$@" ;;
  *)
    echo "Usage: $0 {all|core|publisher|run [args...]}"
    echo ""
    echo "  all        Build FHIR Core, then IG Publisher (default)"
    echo "  core       Build only FHIR Core"
    echo "  publisher  Build only IG Publisher"
    echo "  run        Run the built IG Publisher JAR"
    echo ""
    echo "Detected FHIR Core version: $CORE_VERSION"
    ;;
esac
