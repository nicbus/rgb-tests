#!/bin/bash
#
# script to run project tests and report code coverage
# uses llvm-cov (https://github.com/taiki-e/cargo-llvm-cov)

set -eo pipefail

# --------
# variables
# --------

BINLIST_FILE="target/cov_binlist.txt"
COV=("cargo" "llvm-cov")
COV_OPTS=("--no-report")
CARGO_TEST_OPTS=("--")
COV_RUN_DIR="target/cov_runs"
COV_RUN_FILE="$COV_RUN_DIR/run"
COV_REPORT_TARGET="target/llvm-cov/html"
RUST_TEST_THREADS=1

# --------
# helpers
# --------

_die() {
    echo "ERR: $*"
    exit 1
}

_tit() {
    echo
    echo "========================================"
    echo "$@"
    echo "========================================"
}

# --------
# cmdline
# --------

help() {
    echo "$NAME [<option>] [...]"
    echo ""
    echo "options:"
    echo "    -h   --help             show this help message"
    echo "    -i   --ignore-run-fail  run all tests regardless of failure"
    echo "    -t   --test <test>      only run <test> integration test(s)"
    echo "    -na  --no-altered       don't run altered integration tests"
    echo "    -nes --no-electrum      don't run electrum integration tests"
    echo "    -nel --no-esplora       don't run esplora integration tests"
    echo "    -ni  --no-integration   don't run integration tests"
    echo "    -nu  --no-unit          don't run unit tests for submodules"
    echo "    -tt  --threads <n>      run with <n> test threads (default: 1)"
    echo "         --ci               run in CI mode"
}

while [ -n "$1" ]; do
    case $1 in
        -h | --help)
            help
            exit 0
            ;;
        -i | --ignore-run-fail)
            COV_OPTS+=("--ignore-run-fail")
            ;;
        -t | --test)
            [ -z "$2" ] && _die "test pattern required"
            CARGO_TEST_OPTS+=("$2")
            shift
            ;;
        -na | --no-altered)
            SKIP_ALTERED_TESTS=1
            ;;
        -nes | --no-esplora)
            SKIP_ESPLORA_TESTS=1
            ;;
        -nel | --no-electrum)
            SKIP_ELECTRUM_TESTS=1
            ;;
        -ni | --no-integration)
            SKIP_INTEGRATION_TESTS=1
            ;;
        -nu | --no-unit)
            SKIP_UNIT_TESTS=1
            ;;
        -tt | --threads)
            [ -z "$2" ] && _die "test thread number required"
            if ! [ "$2" -gt 0 ] 2>/dev/null; then
                _die "invalid test thread number ($2)"
            fi
            RUST_TEST_THREADS="$2"
            shift
            ;;
        --ci)
            CI=1
            ;;
        *)
            help
            _die "unsupported argument \"$1\""
            ;;
    esac
    shift
done

# --------
# requirements
# --------

if [ -z "$CI" ]; then
    _tit "installing requirements"
    rustup component add llvm-tools-preview
    cargo install cargo-llvm-cov
fi

# --------
# coverage
# --------

export CARGO_LLVM_COV_TARGET_DIR="target/llvm-cov-target"
export RUST_TEST_THREADS

# initial cleanup + setup
_tit "cleaning previous coverage data"
"${COV[@]}" clean
rm -f $BINLIST_FILE && mkdir -p target && touch $BINLIST_FILE
mkdir -p $COV_RUN_DIR && rm -f $COV_RUN_FILE.*
rm -fr $COV_REPORT_TARGET && mkdir -p $COV_REPORT_TARGET
RUN=0

# tests
_tit "generating coverage data"

## integration tests
if [ "$SKIP_INTEGRATION_TESTS" != 1 ]; then
    export INDEXER=electrum
    # electrum
    if [ "$SKIP_ELECTRUM_TESTS" != 1 ]; then
        "${COV[@]}" "${COV_OPTS[@]}" "${CARGO_TEST_OPTS[@]}" 2>&1 \
            | tee $COV_RUN_FILE.$RUN
        ((RUN += 1))
    fi

    export INDEXER=esplora
    # esplora
    if [ "$SKIP_ESPLORA_TESTS" != 1 ]; then
        "${COV[@]}" "${COV_OPTS[@]}" "${CARGO_TEST_OPTS[@]}" 2>&1 \
            | tee $COV_RUN_FILE.$RUN
        ((RUN += 1))
    fi
    # altered
    if [ "$SKIP_ALTERED_TESTS" != 1 ]; then
        SKIP_INIT=1 "${COV[@]}" "${COV_OPTS[@]}" \
            --features altered "${CARGO_TEST_OPTS[@]}" 2>&1 \
            | tee $COV_RUN_FILE.$RUN
        ((RUN += 1))
    fi

    # cleanup
    unset INDEXER
    docker compose -f tests/compose.yaml --profile='*' down -v --remove-orphans
fi

## unit tests
if [ "$SKIP_UNIT_TESTS" != 1 ]; then
    SUBMODULE_PATHS=$(git submodule | awk '{print $2}' | grep -v altered_submodules)
    for SP in $SUBMODULE_PATHS; do
        FEATURES="--all-features"
        [ "$SP" = "rgb-ascii-armor" ] && FEATURES=""
        "${COV[@]}" "${COV_OPTS[@]}" --manifest-path "$SP/Cargo.toml" \
            --workspace $FEATURES --all-targets 2>&1 \
            | tee $COV_RUN_FILE.$RUN
        ((RUN += 1))
    done
fi

# --------
# report
# --------

_tit "generating coverage report"

# generate unique + sorted binary list from run logs
find $COV_RUN_DIR -type f | while read -r RF; do
    awk -F'(' '/Running/ {print $2}' "$RF" | awk -F')' '{print $1}' >>$BINLIST_FILE
done
sort -u "$BINLIST_FILE" -o "$BINLIST_FILE"

# generate llvm-cov object list from binary list
LLVM_COV_OBJECTS=()
BINLIST=$(cat $BINLIST_FILE)
for B in $BINLIST; do
    LLVM_COV_OBJECTS+=("-object" "$B")
done

# get llvm-cov + llvm-profdata path (version used by cargo-llvm-cov)
RUSTLIB="$(rustc --print sysroot)/lib/rustlib"
RUSTC_HOST="$(rustc -Vv | grep host | awk '{print $2}')"
LLVM_COV="$RUSTLIB/$RUSTC_HOST/bin/llvm-cov"
LLVM_PROFDATA="$RUSTLIB/$RUSTC_HOST/bin/llvm-profdata"

# generate coverage report
# note: manual steps instead of just "llvm-cov report"
#       since cargo llvm-cov excludes the submodules
PROFDATA_PATH="target/llvm-cov-target/rgb-tests.profdata"
IGNORE_PATTERN="/rgb\-tests(/.*)?/(tests|examples|benches)/|/rgb\-tests/target/llvm\-cov\-target($|/)|^$HOME/\.cargo/(registry|git)/|^$HOME/\.rustup/toolchains($|/)"
## merge profraw data
$LLVM_PROFDATA merge -sparse target/llvm-cov-target/*.profraw -o $PROFDATA_PATH
## generate report
if [ -z "$CI" ]; then
    # notes:
    # - options taken from "cargo llvm-cov report --html -v"
    # - run with -dump added (huge output) to debug issues
    $LLVM_COV show \
        --format=html \
        --instr-profile=$PROFDATA_PATH \
        --output-dir=$COV_REPORT_TARGET \
        --ignore-filename-regex "$IGNORE_PATTERN" \
        -show-instantiations=false \
        -show-line-counts-or-regions \
        -show-expansions \
        -show-branches=count \
        -show-mcdc \
        -Xdemangler="$HOME/.cargo/bin/cargo-llvm-cov" \
        -Xdemangler=llvm-cov \
        -Xdemangler=demangle \
        "${LLVM_COV_OBJECTS[@]}"
    # show html report location
    echo "generated html report: target/llvm-cov/html/index.html"
else
    LCOV_FILE="coverage.lcov"
    # note: options taken from "cargo llvm-cov report --lcov -v"
    $LLVM_COV export \
        --format=lcov \
        --instr-profile=$PROFDATA_PATH \
        --ignore-filename-regex="$IGNORE_PATTERN" \
        "${LLVM_COV_OBJECTS[@]}" \
        >$LCOV_FILE
fi
