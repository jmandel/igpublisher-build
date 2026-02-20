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

# ── Versions (update when submodules change) ─────────────────
CORE_VERSION="6.8.2-SNAPSHOT"
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
  mvn clean package $MVN_OPTS -Dcore_version="$CORE_VERSION"
  echo ""
  echo "✓ Built: $JAR"
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
    ;;
esac
