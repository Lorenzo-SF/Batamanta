#!/bin/bash
set -e

run_binary() {
    local bin="$1"
    echo "=== Running $bin ==="
    LD_LIBRARY_PATH=''  # ensure no path interference
    ./$bin
    rc=$?
    if (( rc != 0 )); then
        echo "❌ $bin failed (exit $rc)"
        exit 1
    fi
}

test() {
    rm -fr /tmp/batamant*
    rm -fr ~/.cache/batamanta
    rm -fr deps
    rm -fr _build
    rm -fr test_*-0.1.0-x86_64-linux
    mix deps.get
    mix batamanta
}

for dir in test_cli test_tui test_daemon test_escript \
           test_release_otp27 test_escript_otp26 ; do
    cd "$dir" || exit
    test
    bin_name=$(basename "$dir")-0.1.0-x86_64-linux
    run_binary "$bin_name"
    rm "$bin_name"
    cd ..
 done


