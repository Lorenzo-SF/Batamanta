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
    echo "✅ $bin OK"
}

run_daemon_binary() {
    local bin="$1"
    local signal_file="./daemon_alive.txt"
    echo "=== Running $bin (daemon) ==="
    rm -f "$signal_file"

    # Start daemon in background, capture PID
    LD_LIBRARY_PATH='' ./$bin &
    local wrapper_pid=$!

    # Wait for daemon to signal it started (up to 10s)
    local waited=0
    while [ $waited -lt 100 ]; do
        if [ -f "$signal_file" ]; then
            echo "    Daemon signal file found: $(cat "$signal_file")"
            break
        fi
        sleep 0.1
        waited=$((waited + 1))
    done

    # Check wrapper exit code
    wait $wrapper_pid 2>/dev/null || true
    local rc=$?
    if (( rc != 0 )); then
        echo "❌ $bin wrapper failed (exit $rc)"
        exit 1
    fi

    if [ ! -f "$signal_file" ]; then
        echo "❌ $bin daemon did not produce signal file"
        exit 1
    fi

    # Wait for daemon to finish (graceful shutdown)
    sleep 2
    echo "✅ $bin (daemon) OK"
}

run_escript_binary() {
    local bin="$1"
    echo "=== Running $bin (escript) ==="
    LD_LIBRARY_PATH='' ./$bin --version
    rc=$?
    if (( rc != 0 )); then
        echo "❌ $bin --version failed (exit $rc)"
        exit 1
    fi
    echo "   Version check OK"

    LD_LIBRARY_PATH='' ./$bin info
    rc=$?
    if (( rc != 0 )); then
        echo "❌ $bin info failed (exit $rc)"
        exit 1
    fi
    echo "   Info command OK"

    LD_LIBRARY_PATH='' ./$bin
    rc=$?
    if (( rc != 0 )); then
        echo "❌ $bin (no args) failed (exit $rc)"
        exit 1
    fi
    echo "✅ $bin (escript) OK"
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

for dir in test_release_cli test_cli test_tui test_daemon test_escript \
           test_release_otp27 test_release_nif test_escript_otp26 ; do
    cd "$dir" || exit
    test
    bin_name=$(basename "$dir")-0.1.0-x86_64-linux

    case "$dir" in
        test_daemon|test_release_nif|test_release_otp27)
            run_daemon_binary "$bin_name"
            ;;
        test_escript|test_escript_otp26)
            run_escript_binary "$bin_name"
            ;;
        test_tui)
            echo "=== Skipping $bin_name (TUI) — interactive only ==="
            echo "   Manual test required."
            ;;
        *)
            run_binary "$bin_name"
            ;;
    esac

    rm "$bin_name"
    cd ..
 done


