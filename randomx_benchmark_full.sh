#!/bin/bash

# Complete RandomX v2 Benchmark Script
# - Clones and compiles RandomX from source
# - Applies MSR optimizations for AMD/Intel CPUs
# - Runs benchmark comparison between v1 and v2
# - Auto-detects optimal thread count and affinity
# - Measures power consumption via RAPL
#
# Usage: sudo ./randomx_benchmark_full.sh [OPTIONS]
#   --runs N    Number of benchmark runs per version (default: 100)
#   --nonces N  Number of nonces per run (default: 1000000)
#   --no-msr    Disable MSR optimizations
#   --old-cpu   Old CPU mode (no RAPL, no MSR, software AES)

set -e
set -o pipefail

# Default number of runs
NUM_RUNS=100
# Default nonces per run
NONCES=1000000
# MSR optimizations enabled by default
MSR_ENABLED=1
# Old CPU mode (disables RAPL, MSR, uses software AES)
OLD_CPU=0

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --runs|-r)
            NUM_RUNS="$2"
            shift 2
            ;;
        --nonces|-n)
            NONCES="$2"
            shift 2
            ;;
        --no-msr)
            MSR_ENABLED=0
            shift
            ;;
        --old-cpu)
            OLD_CPU=1
            MSR_ENABLED=0
            shift
            ;;
        --help|-h)
            echo "Usage: sudo $0 [OPTIONS]"
            echo "  --runs N, -r N    Number of benchmark runs per version (default: 100)"
            echo "  --nonces N, -n N  Number of nonces per run (default: 1000000)"
            echo "  --no-msr          Disable MSR optimizations"
            echo "  --old-cpu         Old CPU mode (no RAPL, no MSR, software AES)"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: sudo $0 [--runs N] [--nonces N] [--no-msr] [--old-cpu]"
            exit 1
            ;;
    esac
done

REPO_URL="https://github.com/SChernykh/RandomX.git"
BRANCH="v2"

# Get the real user's home directory (even when running with sudo)
if [ -n "$SUDO_USER" ]; then
    REAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    REAL_HOME="$HOME"
fi
WORK_DIR="$REAL_HOME/randomx_benchmark"

#############################
# Helper Functions
#############################

# Power measurement target (Watts) - adjust for your CPU's TDP
POWER_TARGET=100

# RandomX VM operations per hash (from configuration.h)
# PROGRAM_SIZE × PROGRAM_ITERATIONS × PROGRAM_COUNT
V1_OPS_PER_HASH=$((256 * 2048 * 8))   # = 4,194,304
V2_OPS_PER_HASH=$((384 * 2048 * 8))   # = 6,291,456

#############################
# RAPL Power Measurement
#############################

RAPL_PATH=""
RAPL_AVAILABLE=0

detect_rapl() {
    echo ""
    echo "======================================"
    echo "Detecting RAPL power measurement..."
    echo "======================================"

    # Skip RAPL for old CPUs
    if [ "$OLD_CPU" -eq 1 ]; then
        echo "  RAPL: Disabled (--old-cpu flag)"
        return
    fi

    # Check for Intel RAPL via powercap
    if [ -f "/sys/class/powercap/intel-rapl:0/energy_uj" ]; then
        RAPL_PATH="/sys/class/powercap/intel-rapl:0"
        RAPL_AVAILABLE=1
        echo "  RAPL: Available (intel-rapl powercap)"

        # Check max energy counter for overflow detection
        if [ -f "$RAPL_PATH/max_energy_range_uj" ]; then
            RAPL_MAX=$(cat "$RAPL_PATH/max_energy_range_uj")
            echo "  Max energy range: $((RAPL_MAX / 1000000)) J"
        fi
    # Check for AMD RAPL
    elif [ -f "/sys/class/powercap/amd-rapl:0/energy_uj" ]; then
        RAPL_PATH="/sys/class/powercap/amd-rapl:0"
        RAPL_AVAILABLE=1
        echo "  RAPL: Available (amd-rapl powercap)"
    else
        echo "  RAPL: Not available"
        echo "  Power measurement will be disabled."
        echo "  To enable: ensure your kernel supports powercap and RAPL"
    fi
}

# Read current energy in microjoules
read_energy_uj() {
    if [ $RAPL_AVAILABLE -eq 1 ]; then
        cat "$RAPL_PATH/energy_uj"
    else
        echo "0"
    fi
}

# Calculate energy difference handling overflow
calc_energy_diff_uj() {
    local start=$1
    local end=$2

    if [ $RAPL_AVAILABLE -eq 0 ]; then
        echo "0"
        return
    fi

    if [ "$end" -ge "$start" ]; then
        echo $((end - start))
    else
        # Counter overflow occurred
        local max=$(cat "$RAPL_PATH/max_energy_range_uj" 2>/dev/null || echo "0")
        if [ "$max" -gt 0 ]; then
            echo $((max - start + end))
        else
            echo "0"
        fi
    fi
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "This script requires root privileges for MSR access and package installation."
        echo "Please run with: sudo $0"
        exit 1
    fi
}

setup_hugepages() {
    echo "Setting up hugepages..."
    sysctl -w vm.nr_hugepages=1250
}

#############################
# Dependency Detection
#############################

check_dependencies_installed() {
    echo ""
    echo "======================================"
    echo "Checking if dependencies are installed..."
    echo "======================================"

    local missing=0

    # Check for git
    if ! command -v git &> /dev/null; then
        echo "  git: NOT FOUND"
        missing=1
    else
        echo "  git: OK"
    fi

    # Check for cmake
    if ! command -v cmake &> /dev/null; then
        echo "  cmake: NOT FOUND"
        missing=1
    else
        echo "  cmake: OK"
    fi

    # Check for C++ compiler
    if ! command -v g++ &> /dev/null && ! command -v c++ &> /dev/null; then
        echo "  C++ compiler: NOT FOUND"
        missing=1
    else
        echo "  C++ compiler: OK"
    fi

    # Check for make
    if ! command -v make &> /dev/null; then
        echo "  make: NOT FOUND"
        missing=1
    else
        echo "  make: OK"
    fi

    # Check for wrmsr (msr-tools)
    if ! command -v wrmsr &> /dev/null; then
        echo "  msr-tools (wrmsr): NOT FOUND"
        missing=1
    else
        echo "  msr-tools (wrmsr): OK"
    fi

    # Check for bc (calculator)
    if ! command -v bc &> /dev/null; then
        echo "  bc: NOT FOUND"
        missing=1
    else
        echo "  bc: OK"
    fi

    return $missing
}

check_randomx_built() {
    local binary="$WORK_DIR/RandomX/build/randomx-benchmark"
    if [ -x "$binary" ]; then
        echo ""
        echo "======================================"
        echo "RandomX benchmark already built at:"
        echo "  $binary"
        echo "======================================"
        return 0
    fi
    return 1
}

detect_package_manager() {
    if command -v apt-get &> /dev/null; then
        PKG_MANAGER="apt-get"
        PKG_INSTALL="apt-get install -y"
    elif command -v dnf &> /dev/null; then
        PKG_MANAGER="dnf"
        PKG_INSTALL="dnf install -y"
    elif command -v yum &> /dev/null; then
        PKG_MANAGER="yum"
        PKG_INSTALL="yum install -y"
    elif command -v pacman &> /dev/null; then
        PKG_MANAGER="pacman"
        PKG_INSTALL="pacman -S --noconfirm"
    elif command -v zypper &> /dev/null; then
        PKG_MANAGER="zypper"
        PKG_INSTALL="zypper install -y"
    else
        echo "ERROR: No supported package manager found"
        exit 1
    fi
    echo "Detected package manager: $PKG_MANAGER"
}

install_dependencies() {
    echo ""
    echo "======================================"
    echo "Installing dependencies..."
    echo "======================================"

    case $PKG_MANAGER in
        apt-get)
            apt-get update
            $PKG_INSTALL git cmake build-essential msr-tools bc
            ;;
        dnf|yum)
            $PKG_INSTALL git cmake gcc gcc-c++ make msr-tools bc
            ;;
        pacman)
            $PKG_INSTALL git cmake base-devel msr-tools bc
            ;;
        zypper)
            $PKG_INSTALL git cmake gcc gcc-c++ make msr-tools bc
            ;;
    esac

    echo "Dependencies installed."
}

clone_and_build() {
    echo ""
    echo "======================================"
    echo "Cloning and building RandomX..."
    echo "======================================"

    # Create work directory
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"

    # Clone if not exists, otherwise update
    if [ -d "RandomX" ]; then
        echo "RandomX directory exists, updating..."
        cd RandomX
        git fetch origin
        git checkout $BRANCH
        git pull origin $BRANCH
    else
        echo "Cloning RandomX repository..."
        git clone "$REPO_URL"
        cd RandomX
        git checkout $BRANCH
    fi

    # Build
    echo "Building RandomX..."
    mkdir -p build
    cd build
    cmake -DARCH=native ..
    make -j$(nproc)

    echo "Build complete: $WORK_DIR/RandomX/build/randomx-benchmark"
}

apply_msr_boost() {
    echo ""
    echo "======================================"
    echo "MSR Optimizations"
    echo "======================================"

    if [ "$MSR_ENABLED" -eq 0 ]; then
        echo "  MSR optimizations disabled (--no-msr flag)"
        return
    fi

    echo "Applying MSR optimizations..."

    MSR_FILE=/sys/module/msr/parameters/allow_writes

    if test -e "$MSR_FILE"; then
        echo on > $MSR_FILE
    else
        modprobe msr allow_writes=on
    fi

    if grep -E 'AMD Ryzen|AMD EPYC|AuthenticAMD' /proc/cpuinfo > /dev/null; then
        if grep "cpu family[[:space:]]\{1,\}:[[:space:]]25" /proc/cpuinfo > /dev/null; then
            if grep "model[[:space:]]\{1,\}:[[:space:]]\(97\|117\)" /proc/cpuinfo > /dev/null; then
                echo "Detected Zen4 CPU"
                wrmsr -a 0xc0011020 0x4400000000000
                wrmsr -a 0xc0011021 0x4000000000040
                wrmsr -a 0xc0011022 0x8680000401570000
                wrmsr -a 0xc001102b 0x2040cc10
                echo "MSR register values for Zen4 applied"
            else
                echo "Detected Zen3 CPU"
                wrmsr -a 0xc0011020 0x4480000000000
                wrmsr -a 0xc0011021 0x1c000200000040
                wrmsr -a 0xc0011022 0xc000000401570000
                wrmsr -a 0xc001102b 0x2000cc10
                echo "MSR register values for Zen3 applied"
            fi
        elif grep "cpu family[[:space:]]\{1,\}:[[:space:]]26" /proc/cpuinfo > /dev/null; then
            echo "Detected Zen5 CPU"
            wrmsr -a 0xc0011020 0x4400000000000
            wrmsr -a 0xc0011021 0x4000000000040
            wrmsr -a 0xc0011022 0x8680000401570000
            wrmsr -a 0xc001102b 0x2040cc10
            echo "MSR register values for Zen5 applied"
        else
            echo "Detected Zen1/Zen2 CPU"
            wrmsr -a 0xc0011020 0
            wrmsr -a 0xc0011021 0x40
            wrmsr -a 0xc0011022 0x1510000
            wrmsr -a 0xc001102b 0x2000cc16
            echo "MSR register values for Zen1/Zen2 applied"
        fi
    elif grep "Intel" /proc/cpuinfo > /dev/null; then
        echo "Detected Intel CPU"
        wrmsr -a 0x1a4 0xf
        echo "MSR register values for Intel applied"
    else
        echo "No supported CPU detected for MSR optimization"
    fi
}

#############################
# Auto-detect optimal settings
#############################

detect_optimal_settings() {
    echo ""
    echo "======================================"
    echo "Detecting optimal settings..."
    echo "======================================"

    LOGICAL_CPUS=$(nproc)
    PHYSICAL_CORES=$(lscpu | grep "^Core(s) per socket:" | awk '{print $NF}')
    SOCKETS=$(lscpu | grep "^Socket(s):" | awk '{print $NF}')
    TOTAL_PHYSICAL=$((PHYSICAL_CORES * SOCKETS))

    # Extract cache size from lscpu (portable - no grep -P)
    # Handles both formats: "L3 cache: 64 MiB" and "L3: 64 MiB (instances)"
    parse_cache_size() {
        # Extract number before MiB/GiB/MB/GB/KiB/KB
        echo "$1" | sed -n 's/.*[[:space:]]\([0-9]\+\)[[:space:]]*[MGK]i\?B.*/\1/p' | head -1
    }

    L3_LINE=$(lscpu | grep -E "^[[:space:]]*L3" || true)
    L3_CACHE_MB=$(parse_cache_size "$L3_LINE")

    if [ -z "$L3_CACHE_MB" ] || [ "$L3_CACHE_MB" -eq 0 ] 2>/dev/null; then
        # No L3 cache - try L2 (older CPUs like Core 2 Quad)
        L2_LINE=$(lscpu | grep -E "^[[:space:]]*L2" || true)
        L2_CACHE_MB=$(parse_cache_size "$L2_LINE")
        if [ -n "$L2_CACHE_MB" ] && [ "$L2_CACHE_MB" -gt 0 ] 2>/dev/null; then
            CACHE_MB=$L2_CACHE_MB
            CACHE_TYPE="L2"
        else
            # Fallback: assume enough cache for all cores
            CACHE_MB=$((LOGICAL_CPUS * 2))
            CACHE_TYPE="unknown"
        fi
    else
        CACHE_MB=$L3_CACHE_MB
        CACHE_TYPE="L3"
    fi

    # Each RandomX thread needs 2MB of cache
    MAX_THREADS_BY_CACHE=$((CACHE_MB / 2))
    # Ensure at least 1 thread
    [ "$MAX_THREADS_BY_CACHE" -lt 1 ] && MAX_THREADS_BY_CACHE=1

    # Optimal threads is the minimum of logical CPUs and cache-limited threads
    OPTIMAL_THREADS=$((LOGICAL_CPUS < MAX_THREADS_BY_CACHE ? LOGICAL_CPUS : MAX_THREADS_BY_CACHE))
    [ "$OPTIMAL_THREADS" -lt 1 ] && OPTIMAL_THREADS=1

    # Init threads = all logical CPUs for fastest dataset initialization
    INIT_THREADS=$LOGICAL_CPUS

    # Calculate optimal affinity mask based on CPU topology
    AFFINITY_MASK=$(calculate_affinity $OPTIMAL_THREADS)

    echo "System detected:"
    echo "  CPU: $(lscpu | grep 'Model name' | sed 's/Model name:\s*//')"
    echo "  Logical CPUs: $LOGICAL_CPUS"
    echo "  Physical cores: $TOTAL_PHYSICAL"
    echo "  ${CACHE_TYPE} Cache: ${CACHE_MB} MB"
    echo "  Max threads by cache: $MAX_THREADS_BY_CACHE"
    echo "  Optimal mining threads: $OPTIMAL_THREADS"
    echo "  Init threads: $INIT_THREADS"
    echo "  Affinity mask: $AFFINITY_MASK"
}

# Calculate optimal affinity mask based on CPU topology
# Strategy: select physical cores first, spread across L3 cache domains
calculate_affinity() {
    local num_threads=$1
    local selected_cpus=()
    local l3_domains=()
    local cpu_by_core_l3=()
    local LOGICAL_CPUS=$(nproc)

    # Build list of first CPU for each physical core, grouped by L3
    for cpunum in $(seq 0 $((LOGICAL_CPUS - 1))); do
        local sysfs="/sys/devices/system/cpu/cpu$cpunum"
        [ -f "$sysfs/topology/core_id" ] || continue
        local core=$(cat "$sysfs/topology/core_id")
        local l3=$(cat "$sysfs/cache/index3/id" 2>/dev/null || echo "0")
        local key="${l3}_${core}"
        # Only record first CPU for each physical core (skip SMT siblings)
        local found=0
        for existing in "${cpu_by_core_l3[@]}"; do
            if [ "$existing" = "$key" ]; then
                found=1
                break
            fi
        done
        if [ $found -eq 0 ]; then
            cpu_by_core_l3+=("$key")
            l3_domains+=("$l3:$cpunum")
        fi
    done

    # Sort by L3 domain to interleave across CCDs
    IFS=$'\n' sorted=($(printf '%s\n' "${l3_domains[@]}" | sort -t: -k1,1n -k2,2n))
    unset IFS

    # Find max L3 domain
    local max_l3=0
    for entry in "${sorted[@]}"; do
        l3=${entry%%:*}
        ((l3 > max_l3)) && max_l3=$l3
    done

    # Round-robin across L3 domains
    local selected=0
    while [ $selected -lt $num_threads ] && [ $selected -lt ${#sorted[@]} ]; do
        for l3 in $(seq 0 $max_l3); do
            [ $selected -ge $num_threads ] && break
            for entry in "${sorted[@]}"; do
                entry_l3=${entry%%:*}
                entry_cpu=${entry#*:}
                local already_selected=0
                for sel in "${selected_cpus[@]}"; do
                    if [ "$sel" = "$entry_cpu" ]; then
                        already_selected=1
                        break
                    fi
                done
                if [ "$entry_l3" -eq "$l3" ] && [ $already_selected -eq 0 ]; then
                    selected_cpus+=("$entry_cpu")
                    ((selected++))
                    break
                fi
            done
        done
    done

    # If we need more threads than physical cores, add SMT siblings
    if [ $selected -lt $num_threads ]; then
        for cpunum in $(seq 0 $((LOGICAL_CPUS - 1))); do
            [ $selected -ge $num_threads ] && break
            local already_selected=0
            for sel in "${selected_cpus[@]}"; do
                if [ "$sel" = "$cpunum" ]; then
                    already_selected=1
                    break
                fi
            done
            if [ $already_selected -eq 0 ]; then
                selected_cpus+=("$cpunum")
                ((selected++))
            fi
        done
    fi

    # Build affinity mask
    local mask=0
    for cpu in "${selected_cpus[@]}"; do
        mask=$((mask | (1 << cpu)))
    done
    printf "0x%X" $mask
}

#############################
# Benchmark Functions
#############################

run_benchmarks() {
    echo ""
    echo "======================================"
    echo "Running benchmarks..."
    echo "======================================"

    cd "$WORK_DIR/RandomX/build"

    V2_SEGFAULTS=0
    V1_SEGFAULTS=0
    V2_SUCCESS=0
    V1_SUCCESS=0

    # Build base command
    if [ "$OLD_CPU" -eq 1 ]; then
        # Old CPU: software AES, no AVX2
        BASE_CMD="./randomx-benchmark --mine --jit --largePages --threads $OPTIMAL_THREADS --affinity $AFFINITY_MASK --init $INIT_THREADS --nonces $NONCES --softAes"
    else
        BASE_CMD="./randomx-benchmark --mine --jit --largePages --threads $OPTIMAL_THREADS --affinity $AFFINITY_MASK --init $INIT_THREADS --nonces $NONCES --avx2"
    fi

    # Results file with timestamp
    RESULTS_FILE="$WORK_DIR/benchmark_results_$(date +%Y%m%d_%H%M%S).txt"

    # Temp files for metrics
    V2_HASHRATES_FILE=$(mktemp)
    V1_HASHRATES_FILE=$(mktemp)
    V2_ENERGY_FILE=$(mktemp)
    V1_ENERGY_FILE=$(mktemp)
    V2_TIME_FILE=$(mktemp)
    V1_TIME_FILE=$(mktemp)

    # Cleanup temp files on exit
    trap "rm -f $V2_HASHRATES_FILE $V1_HASHRATES_FILE $V2_ENERGY_FILE $V1_ENERGY_FILE $V2_TIME_FILE $V1_TIME_FILE" EXIT

    echo ""
    echo "Base command: $BASE_CMD"
    echo "Results will be saved to: $RESULTS_FILE"
    echo ""

    # Disable set -e for benchmark loops (we handle crashes explicitly)
    set +e
    set +o pipefail

    # Run with --v2
    echo "Testing with --v2 flag ($NUM_RUNS runs)..."
    echo ""
    for i in $(seq 1 $NUM_RUNS); do
        echo "--- Run $i/$NUM_RUNS (v2) ---"
        echo "Command: $BASE_CMD --v2"

        # Use temp file and tee for unbuffered streaming output
        TEMP_OUTPUT=$(mktemp)

        # Record start energy and time
        START_ENERGY=$(read_energy_uj)
        START_TIME=$(date +%s.%N)

        $BASE_CMD --v2 2>&1 | tee "$TEMP_OUTPUT"
        EXIT_CODE=${PIPESTATUS[0]}

        # Record end energy and time
        END_TIME=$(date +%s.%N)
        END_ENERGY=$(read_energy_uj)

        if [ $EXIT_CODE -eq 139 ] || [ $EXIT_CODE -eq 134 ] || [ $EXIT_CODE -ne 0 ]; then
            ((V2_SEGFAULTS++))
            echo ">>> Result: CRASH (exit code: $EXIT_CODE)"
        else
            ((V2_SUCCESS++))
            # Extract hashrate (looks for "Performance: X hashes per second")
            HASHRATE=$(grep -oP 'Performance:\s*[\d.]+' "$TEMP_OUTPUT" | grep -oP '[\d.]+')

            if [ -n "$HASHRATE" ]; then
                echo "$HASHRATE" >> "$V2_HASHRATES_FILE"
            fi

            # Calculate and store energy/time
            ENERGY_UJ=$(calc_energy_diff_uj "$START_ENERGY" "$END_ENERGY")
            RUNTIME=$(echo "$END_TIME - $START_TIME" | bc)
            echo "$ENERGY_UJ" >> "$V2_ENERGY_FILE"
            echo "$RUNTIME" >> "$V2_TIME_FILE"

            # Calculate power for this run
            if [ "$ENERGY_UJ" -gt 0 ] && [ "$RAPL_AVAILABLE" -eq 1 ]; then
                POWER_W=$(echo "scale=2; $ENERGY_UJ / 1000000 / $RUNTIME" | bc)
                echo ">>> Result: OK (Hashrate: $HASHRATE H/s, Power: ${POWER_W}W)"
            else
                echo ">>> Result: OK (Hashrate: $HASHRATE H/s)"
            fi
        fi
        rm -f "$TEMP_OUTPUT"
        echo ""
    done

    echo ""
    echo "V2 testing complete. Crashes: $V2_SEGFAULTS / $NUM_RUNS"
    echo ""

    # Run without --v2
    echo "Testing without --v2 flag ($NUM_RUNS runs)..."
    echo ""
    for i in $(seq 1 $NUM_RUNS); do
        echo "--- Run $i/$NUM_RUNS (v1) ---"
        echo "Command: $BASE_CMD"

        # Use temp file and tee for unbuffered streaming output
        TEMP_OUTPUT=$(mktemp)

        # Record start energy and time
        START_ENERGY=$(read_energy_uj)
        START_TIME=$(date +%s.%N)

        $BASE_CMD 2>&1 | tee "$TEMP_OUTPUT"
        EXIT_CODE=${PIPESTATUS[0]}

        # Record end energy and time
        END_TIME=$(date +%s.%N)
        END_ENERGY=$(read_energy_uj)

        if [ $EXIT_CODE -eq 139 ] || [ $EXIT_CODE -eq 134 ] || [ $EXIT_CODE -ne 0 ]; then
            ((V1_SEGFAULTS++))
            echo ">>> Result: CRASH (exit code: $EXIT_CODE)"
        else
            ((V1_SUCCESS++))
            # Extract hashrate (looks for "Performance: X hashes per second")
            HASHRATE=$(grep -oP 'Performance:\s*[\d.]+' "$TEMP_OUTPUT" | grep -oP '[\d.]+')

            if [ -n "$HASHRATE" ]; then
                echo "$HASHRATE" >> "$V1_HASHRATES_FILE"
            fi

            # Calculate and store energy/time
            ENERGY_UJ=$(calc_energy_diff_uj "$START_ENERGY" "$END_ENERGY")
            RUNTIME=$(echo "$END_TIME - $START_TIME" | bc)
            echo "$ENERGY_UJ" >> "$V1_ENERGY_FILE"
            echo "$RUNTIME" >> "$V1_TIME_FILE"

            # Calculate power for this run
            if [ "$ENERGY_UJ" -gt 0 ] && [ "$RAPL_AVAILABLE" -eq 1 ]; then
                POWER_W=$(echo "scale=2; $ENERGY_UJ / 1000000 / $RUNTIME" | bc)
                echo ">>> Result: OK (Hashrate: $HASHRATE H/s, Power: ${POWER_W}W)"
            else
                echo ">>> Result: OK (Hashrate: $HASHRATE H/s)"
            fi
        fi
        rm -f "$TEMP_OUTPUT"
        echo ""
    done

    # Re-enable error handling
    set -e

    # Calculate and display results
    display_results
}

# Calculate statistics using awk
calc_stats() {
    local file=$1
    if [ -s "$file" ]; then
        awk '
        BEGIN { sum=0; sumsq=0; n=0; min=999999999; max=0 }
        {
            sum += $1
            sumsq += $1 * $1
            n++
            if ($1 < min) min = $1
            if ($1 > max) max = $1
        }
        END {
            if (n > 0) {
                avg = sum / n
                if (n > 1) {
                    stdev = sqrt((sumsq - sum*sum/n) / (n-1))
                } else {
                    stdev = 0
                }
                printf "%.2f %.2f %.2f %.2f %d", avg, stdev, min, max, n
            } else {
                print "0 0 0 0 0"
            }
        }' "$file"
    else
        echo "0 0 0 0 0"
    fi
}

display_results() {
    # Get hashrate statistics
    V2_STATS=$(calc_stats "$V2_HASHRATES_FILE")
    V1_STATS=$(calc_stats "$V1_HASHRATES_FILE")

    V2_HASHRATE=$(echo "$V2_STATS" | cut -d' ' -f1)
    V2_STDEV=$(echo "$V2_STATS" | cut -d' ' -f2)
    V2_MIN=$(echo "$V2_STATS" | cut -d' ' -f3)
    V2_MAX=$(echo "$V2_STATS" | cut -d' ' -f4)
    V2_COUNT=$(echo "$V2_STATS" | cut -d' ' -f5)

    V1_HASHRATE=$(echo "$V1_STATS" | cut -d' ' -f1)
    V1_STDEV=$(echo "$V1_STATS" | cut -d' ' -f2)
    V1_MIN=$(echo "$V1_STATS" | cut -d' ' -f3)
    V1_MAX=$(echo "$V1_STATS" | cut -d' ' -f4)
    V1_COUNT=$(echo "$V1_STATS" | cut -d' ' -f5)

    # Calculate VM+AES operations per second from hashrate
    # Using known constants from RandomX configuration.h
    if [ "$V1_HASHRATE" != "0" ] && [ -n "$V1_HASHRATE" ]; then
        V1_VMAES=$(echo "scale=0; $V1_HASHRATE * $V1_OPS_PER_HASH" | bc)
    else
        V1_VMAES="0"
    fi
    if [ "$V2_HASHRATE" != "0" ] && [ -n "$V2_HASHRATE" ]; then
        V2_VMAES=$(echo "scale=0; $V2_HASHRATE * $V2_OPS_PER_HASH" | bc)
    else
        V2_VMAES="0"
    fi

    # Get energy statistics (sum of all energy in microjoules)
    V2_TOTAL_ENERGY_UJ=$(awk '{sum+=$1} END {print sum}' "$V2_ENERGY_FILE" 2>/dev/null || echo "0")
    V1_TOTAL_ENERGY_UJ=$(awk '{sum+=$1} END {print sum}' "$V1_ENERGY_FILE" 2>/dev/null || echo "0")
    V2_TOTAL_TIME=$(awk '{sum+=$1} END {print sum}' "$V2_TIME_FILE" 2>/dev/null || echo "0")
    V1_TOTAL_TIME=$(awk '{sum+=$1} END {print sum}' "$V1_TIME_FILE" 2>/dev/null || echo "0")

    # Convert to Joules
    V2_TOTAL_ENERGY_J=$(echo "scale=2; $V2_TOTAL_ENERGY_UJ / 1000000" | bc)
    V1_TOTAL_ENERGY_J=$(echo "scale=2; $V1_TOTAL_ENERGY_UJ / 1000000" | bc)

    # Calculate average power (Watts)
    if [ "$V2_TOTAL_TIME" != "0" ] && [ -n "$V2_TOTAL_TIME" ]; then
        V2_AVG_POWER=$(echo "scale=2; $V2_TOTAL_ENERGY_J / $V2_TOTAL_TIME" | bc)
    else
        V2_AVG_POWER="N/A"
    fi
    if [ "$V1_TOTAL_TIME" != "0" ] && [ -n "$V1_TOTAL_TIME" ]; then
        V1_AVG_POWER=$(echo "scale=2; $V1_TOTAL_ENERGY_J / $V1_TOTAL_TIME" | bc)
    else
        V1_AVG_POWER="N/A"
    fi

    # Calculate Hash/Joule (efficiency)
    # Use average power for H/J calculation: H/J = Hashrate / Power
    if [ "$V2_AVG_POWER" != "N/A" ] && [ "$V2_AVG_POWER" != "0" ]; then
        V2_HASH_PER_JOULE=$(echo "scale=2; $V2_HASHRATE / $V2_AVG_POWER" | bc)
    else
        V2_HASH_PER_JOULE="N/A"
    fi
    if [ "$V1_AVG_POWER" != "N/A" ] && [ "$V1_AVG_POWER" != "0" ]; then
        V1_HASH_PER_JOULE=$(echo "scale=2; $V1_HASHRATE / $V1_AVG_POWER" | bc)
    else
        V1_HASH_PER_JOULE="N/A"
    fi

    # Calculate VM+AES/Joule
    if [ "$V2_AVG_POWER" != "N/A" ] && [ "$V2_AVG_POWER" != "0" ] && [ "$V2_VMAES" != "0" ] && [ -n "$V2_VMAES" ]; then
        V2_VMAES_PER_JOULE=$(echo "scale=2; $V2_VMAES / $V2_AVG_POWER" | bc)
    else
        V2_VMAES_PER_JOULE="N/A"
    fi
    if [ "$V1_AVG_POWER" != "N/A" ] && [ "$V1_AVG_POWER" != "0" ] && [ "$V1_VMAES" != "0" ] && [ -n "$V1_VMAES" ]; then
        V1_VMAES_PER_JOULE=$(echo "scale=2; $V1_VMAES / $V1_AVG_POWER" | bc)
    else
        V1_VMAES_PER_JOULE="N/A"
    fi

    # Calculate relative speed (V1 = 100%)
    if [ "$V1_HASHRATE" != "0" ] && [ -n "$V1_HASHRATE" ]; then
        V1_REL_SPEED="100.0"
        V2_REL_SPEED=$(echo "scale=1; ($V2_HASHRATE / $V1_HASHRATE) * 100" | bc)
    else
        V1_REL_SPEED="100.0"
        V2_REL_SPEED="N/A"
    fi

    # Calculate relative work/Joule (V1 = 100%)
    if [ "$V1_VMAES_PER_JOULE" != "N/A" ] && [ "$V1_VMAES_PER_JOULE" != "0" ] && [ "$V2_VMAES_PER_JOULE" != "N/A" ]; then
        V1_REL_WORK_JOULE="100.0"
        V2_REL_WORK_JOULE=$(echo "scale=1; ($V2_VMAES_PER_JOULE / $V1_VMAES_PER_JOULE) * 100" | bc)
    else
        V1_REL_WORK_JOULE="100.0"
        V2_REL_WORK_JOULE="N/A"
    fi

    CPU_MODEL=$(lscpu | grep 'Model name' | sed 's/Model name:\s*//' | xargs)

    # Format large numbers with scientific notation
    format_sci() {
        local val=$1
        if [ "$val" = "N/A" ] || [ -z "$val" ] || [ "$val" = "0" ]; then
            echo "N/A"
        else
            echo "$val" | awk '{
                if ($1 >= 1e9) printf "%.2fe9", $1/1e9
                else if ($1 >= 1e6) printf "%.2fe6", $1/1e6
                else printf "%.2f", $1
            }'
        fi
    }

    V1_VMAES_FMT=$(format_sci "$V1_VMAES")
    V2_VMAES_FMT=$(format_sci "$V2_VMAES")
    V1_VMAES_J_FMT=$(format_sci "$V1_VMAES_PER_JOULE")
    V2_VMAES_J_FMT=$(format_sci "$V2_VMAES_PER_JOULE")

    # Output results (terminal friendly)
    OUTPUT_RESULTS() {
        echo ""
        echo "======================================"
        echo "FINAL RESULTS"
        echo "======================================"
        echo "System: $CPU_MODEL"
        echo "Threads: $OPTIMAL_THREADS | Affinity: $AFFINITY_MASK | Init: $INIT_THREADS"
        echo "Power Target: ${POWER_TARGET}W (configured)"
        echo ""
        echo "V2 (with --v2 flag):"
        echo "  Crashes:       $V2_SEGFAULTS / $NUM_RUNS"
        echo "  Success:       $V2_SUCCESS / $NUM_RUNS"
        echo "  Avg Hashrate:  $V2_HASHRATE H/s"
        echo "  Relative:      ${V2_REL_SPEED}%"
        echo "  Avg Power:     ${V2_AVG_POWER}W"
        echo "  Hash/Joule:    $V2_HASH_PER_JOULE"
        echo "  VM+AES/s:      $V2_VMAES_FMT"
        echo "  VM+AES/Joule:  $V2_VMAES_J_FMT"
        echo ""
        echo "V1 (without --v2 flag):"
        echo "  Crashes:       $V1_SEGFAULTS / $NUM_RUNS"
        echo "  Success:       $V1_SUCCESS / $NUM_RUNS"
        echo "  Avg Hashrate:  $V1_HASHRATE H/s"
        echo "  Relative:      ${V1_REL_SPEED}%"
        echo "  Avg Power:     ${V1_AVG_POWER}W"
        echo "  Hash/Joule:    $V1_HASH_PER_JOULE"
        echo "  VM+AES/s:      $V1_VMAES_FMT"
        echo "  VM+AES/Joule:  $V1_VMAES_J_FMT"
        echo ""
        echo "======================================"
    }

    # GitHub markdown summary - matches developer's table format
    GITHUB_SUMMARY() {
        echo ""
        echo "======================================"
        echo "GITHUB COPY-PASTE SUMMARY (Markdown)"
        echo "======================================"
        echo ""
        echo "### RandomX v2 Benchmark Results"
        echo ""
        echo "**$CPU_MODEL @ ${V1_AVG_POWER}W**"
        echo ""
        echo "| Algorithm | Hashrate | Relative Speed | Hash/Joule | VM+AES/s | VM+AES/Joule | Relative Work/Joule |"
        echo "|-----------|----------|----------------|------------|----------|--------------|---------------------|"
        echo "| RandomX v1 | $V1_HASHRATE | ${V1_REL_SPEED}% | $V1_HASH_PER_JOULE | $V1_VMAES_FMT | $V1_VMAES_J_FMT | ${V1_REL_WORK_JOULE}% |"
        echo "| RandomX v2 | $V2_HASHRATE | ${V2_REL_SPEED}% | $V2_HASH_PER_JOULE | $V2_VMAES_FMT | $V2_VMAES_J_FMT | ${V2_REL_WORK_JOULE}% |"
        echo ""
        echo "**Config:** threads=$OPTIMAL_THREADS, affinity=$AFFINITY_MASK, init=$INIT_THREADS"
        echo ""
        echo "**Stability:** V1 crashes: $V1_SEGFAULTS/$NUM_RUNS, V2 crashes: $V2_SEGFAULTS/$NUM_RUNS"
        echo ""
        echo "---"
        echo ""
        echo "<details>"
        echo "<summary>Detailed Statistics</summary>"
        echo ""
        echo "| Metric | V1 | V2 |"
        echo "|--------|----|----|"
        echo "| Successful runs | $V1_COUNT | $V2_COUNT |"
        echo "| Hashrate (avg) | $V1_HASHRATE H/s | $V2_HASHRATE H/s |"
        echo "| Hashrate (std dev) | $V1_STDEV H/s | $V2_STDEV H/s |"
        echo "| Hashrate (min) | $V1_MIN H/s | $V2_MIN H/s |"
        echo "| Hashrate (max) | $V1_MAX H/s | $V2_MAX H/s |"
        echo "| Total energy | ${V1_TOTAL_ENERGY_J} J | ${V2_TOTAL_ENERGY_J} J |"
        echo "| Total time | ${V1_TOTAL_TIME} s | ${V2_TOTAL_TIME} s |"
        echo "| Average power | ${V1_AVG_POWER} W | ${V2_AVG_POWER} W |"
        echo ""
        echo "</details>"
        echo ""
        echo "======================================"
    }

    # Print to screen and save to file
    OUTPUT_RESULTS | tee "$RESULTS_FILE"
    GITHUB_SUMMARY | tee -a "$RESULTS_FILE"

    # Also save raw data to results file
    echo "" >> "$RESULTS_FILE"
    echo "Raw V2 Hashrates:" >> "$RESULTS_FILE"
    cat "$V2_HASHRATES_FILE" >> "$RESULTS_FILE" 2>/dev/null
    echo "" >> "$RESULTS_FILE"
    echo "Raw V1 Hashrates:" >> "$RESULTS_FILE"
    cat "$V1_HASHRATES_FILE" >> "$RESULTS_FILE" 2>/dev/null
    echo "" >> "$RESULTS_FILE"
    echo "Raw V2 Energy (uJ):" >> "$RESULTS_FILE"
    cat "$V2_ENERGY_FILE" >> "$RESULTS_FILE" 2>/dev/null
    echo "" >> "$RESULTS_FILE"
    echo "Raw V1 Energy (uJ):" >> "$RESULTS_FILE"
    cat "$V1_ENERGY_FILE" >> "$RESULTS_FILE" 2>/dev/null

    echo ""
    echo "Results saved to: $RESULTS_FILE"
}

#############################
# Main
#############################

main() {
    echo "======================================"
    echo "RandomX v2 Benchmark Suite"
    echo "======================================"
    echo ""

    check_root
    setup_hugepages
    detect_rapl

    # Check if dependencies are already installed
    if check_dependencies_installed; then
        echo ""
        echo "All dependencies already installed. Skipping installation."
    else
        echo ""
        echo "Some dependencies missing. Installing..."
        detect_package_manager
        install_dependencies
    fi

    # Check if RandomX is already built
    if check_randomx_built; then
        echo "Skipping clone and build."
    else
        echo ""
        echo "RandomX benchmark not found. Building..."
        clone_and_build
    fi

    apply_msr_boost
    detect_optimal_settings
    run_benchmarks

    echo ""
    echo "======================================"
    echo "Benchmark complete!"
    echo "======================================"
}

main "$@"
