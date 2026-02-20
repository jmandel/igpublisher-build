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

The IG Publisher depends on FHIR Core artifacts (groupId `ca.uhn.hapi.fhir`). By building FHIR Core first with `mvn install`, its SNAPSHOT jars land in your local Maven repository (`~/.m2/repository/`). The IG Publisher build then resolves those same artifacts locally instead of downloading from Maven Central.

### Build Steps

| Step | What Happens |
|------|-------------|
| `./rebuild.sh core` | Builds FHIR Core (`6.8.2-SNAPSHOT`) and installs it to `~/.m2/repository` |
| `./rebuild.sh publisher` | Builds the IG Publisher with `-Dcore_version=6.8.2-SNAPSHOT`, pulling FHIR Core from the local repo. Produces a fat JAR via maven-shade-plugin |
| `./rebuild.sh all` | Runs both steps in order (default) |
| `./rebuild.sh run [args]` | Runs the built IG Publisher JAR |

### Making Changes

1. **Edit FHIR Core** — make your change in `org.hl7.fhir.core/`
2. **Rebuild Core** — `./rebuild.sh core` (installs updated SNAPSHOT to `~/.m2`)
3. **Rebuild Publisher** — `./rebuild.sh publisher` (picks up updated SNAPSHOT)
4. **Run** — `./rebuild.sh run -ig /path/to/ig`

For changes to the IG Publisher itself, skip step 1–2 and just run `./rebuild.sh publisher`.

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
- The IG Publisher's released `core_version` is `6.8.1`. This repo overrides it to `6.8.2-SNAPSHOT` to use the local FHIR Core build.
- Update the `CORE_VERSION` and `PUBLISHER_VERSION` variables in `rebuild.sh` if submodule versions change.
