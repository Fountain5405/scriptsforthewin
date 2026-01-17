#!/bin/bash

# Complete RandomX v2 Benchmark Script
# - Clones and compiles RandomX from source
# - Applies MSR optimizations for AMD/Intel CPUs
# - Runs benchmark comparison between v1 and v2
# - Auto-detects optimal thread count and affinity

set -e
set -o pipefail

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
            $PKG_INSTALL git cmake build-essential msr-tools
            ;;
        dnf|yum)
            $PKG_INSTALL git cmake gcc gcc-c++ make msr-tools
            ;;
        pacman)
            $PKG_INSTALL git cmake base-devel msr-tools
            ;;
        zypper)
            $PKG_INSTALL git cmake gcc gcc-c++ make msr-tools
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
    echo "Applying MSR optimizations..."
    echo "======================================"

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

    # Extract L3 cache size (e.g., "64 MiB" -> 64)
    L3_CACHE_MB=$(lscpu | grep "L3 cache" | grep -oP ':\s*\K[\d]+' | head -1)

    # Each RandomX thread needs 2MB of L3 cache
    MAX_THREADS_BY_CACHE=$((L3_CACHE_MB / 2))

    # Optimal threads is the minimum of logical CPUs and cache-limited threads
    OPTIMAL_THREADS=$((LOGICAL_CPUS < MAX_THREADS_BY_CACHE ? LOGICAL_CPUS : MAX_THREADS_BY_CACHE))

    # Init threads = all logical CPUs for fastest dataset initialization
    INIT_THREADS=$LOGICAL_CPUS

    # Calculate optimal affinity mask based on CPU topology
    AFFINITY_MASK=$(calculate_affinity $OPTIMAL_THREADS)

    echo "System detected:"
    echo "  CPU: $(lscpu | grep 'Model name' | sed 's/Model name:\s*//')"
    echo "  Logical CPUs: $LOGICAL_CPUS"
    echo "  Physical cores: $TOTAL_PHYSICAL"
    echo "  L3 Cache: ${L3_CACHE_MB} MB"
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

    BASE_CMD="./randomx-benchmark --mine --jit --largePages --threads $OPTIMAL_THREADS --affinity $AFFINITY_MASK --init $INIT_THREADS --nonces 1000000 --avx2"

    # Results file with timestamp
    RESULTS_FILE="$WORK_DIR/benchmark_results_$(date +%Y%m%d_%H%M%S).txt"
    V2_HASHRATES_FILE=$(mktemp)
    V1_HASHRATES_FILE=$(mktemp)

    # Cleanup temp files on exit
    trap "rm -f $V2_HASHRATES_FILE $V1_HASHRATES_FILE" EXIT

    echo ""
    echo "Base command: $BASE_CMD"
    echo "Results will be saved to: $RESULTS_FILE"
    echo ""

    # Disable set -e for benchmark loops (we handle crashes explicitly)
    set +e
    set +o pipefail

    # Run 100 times with --v2
    echo "Testing with --v2 flag (100 runs)..."
    echo ""
    for i in $(seq 1 100); do
        echo "--- Run $i/100 (v2) ---"
        echo "Command: $BASE_CMD --v2"

        # Use temp file and tee for unbuffered streaming output
        TEMP_OUTPUT=$(mktemp)
        $BASE_CMD --v2 2>&1 | tee "$TEMP_OUTPUT"
        EXIT_CODE=${PIPESTATUS[0]}

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
            echo ">>> Result: OK (Hashrate: $HASHRATE H/s)"
        fi
        rm -f "$TEMP_OUTPUT"
        echo ""
    done

    echo ""
    echo "V2 testing complete. Crashes: $V2_SEGFAULTS / 100"
    echo ""

    # Run 100 times without --v2
    echo "Testing without --v2 flag (100 runs)..."
    echo ""
    for i in $(seq 1 100); do
        echo "--- Run $i/100 (v1) ---"
        echo "Command: $BASE_CMD"

        # Use temp file and tee for unbuffered streaming output
        TEMP_OUTPUT=$(mktemp)
        $BASE_CMD 2>&1 | tee "$TEMP_OUTPUT"
        EXIT_CODE=${PIPESTATUS[0]}

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
            echo ">>> Result: OK (Hashrate: $HASHRATE H/s)"
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
    # Get statistics
    V2_STATS=$(calc_stats "$V2_HASHRATES_FILE")
    V1_STATS=$(calc_stats "$V1_HASHRATES_FILE")

    V2_AVG=$(echo "$V2_STATS" | cut -d' ' -f1)
    V2_STDEV=$(echo "$V2_STATS" | cut -d' ' -f2)
    V2_MIN=$(echo "$V2_STATS" | cut -d' ' -f3)
    V2_MAX=$(echo "$V2_STATS" | cut -d' ' -f4)
    V2_COUNT=$(echo "$V2_STATS" | cut -d' ' -f5)

    V1_AVG=$(echo "$V1_STATS" | cut -d' ' -f1)
    V1_STDEV=$(echo "$V1_STATS" | cut -d' ' -f2)
    V1_MIN=$(echo "$V1_STATS" | cut -d' ' -f3)
    V1_MAX=$(echo "$V1_STATS" | cut -d' ' -f4)
    V1_COUNT=$(echo "$V1_STATS" | cut -d' ' -f5)

    # Calculate difference
    if [ "$V1_AVG" != "0" ] && [ -n "$V1_AVG" ]; then
        DIFF=$(awk "BEGIN { printf \"%.2f\", $V2_AVG - $V1_AVG }")
        DIFF_PCT=$(awk "BEGIN { printf \"%.2f\", (($V2_AVG - $V1_AVG) / $V1_AVG) * 100 }")
    else
        DIFF="N/A"
        DIFF_PCT="N/A"
    fi

    # Determine comparison result
    if [ "$DIFF_PCT" != "N/A" ]; then
        if (( $(echo "$DIFF > 0" | bc -l) )); then
            COMPARISON="V2 is FASTER than V1"
        elif (( $(echo "$DIFF < 0" | bc -l) )); then
            COMPARISON="V2 is SLOWER than V1"
        else
            COMPARISON="V2 and V1 have the same performance"
        fi
    else
        COMPARISON="N/A"
    fi

    CPU_MODEL=$(lscpu | grep 'Model name' | sed 's/Model name:\s*//')

    # Output results (terminal friendly)
    OUTPUT_RESULTS() {
        echo ""
        echo "======================================"
        echo "FINAL RESULTS"
        echo "======================================"
        echo "System: $CPU_MODEL"
        echo "Threads: $OPTIMAL_THREADS | Affinity: $AFFINITY_MASK | Init: $INIT_THREADS"
        echo ""
        echo "V2 (with --v2 flag):"
        echo "  Crashes:   $V2_SEGFAULTS / 100"
        echo "  Success:   $V2_SUCCESS / 100"
        echo "  Hashrate Statistics (from $V2_COUNT successful runs):"
        echo "    Average: $V2_AVG H/s"
        echo "    Std Dev: $V2_STDEV H/s"
        echo "    Min:     $V2_MIN H/s"
        echo "    Max:     $V2_MAX H/s"
        echo ""
        echo "V1 (without --v2 flag):"
        echo "  Crashes:   $V1_SEGFAULTS / 100"
        echo "  Success:   $V1_SUCCESS / 100"
        echo "  Hashrate Statistics (from $V1_COUNT successful runs):"
        echo "    Average: $V1_AVG H/s"
        echo "    Std Dev: $V1_STDEV H/s"
        echo "    Min:     $V1_MIN H/s"
        echo "    Max:     $V1_MAX H/s"
        echo ""
        echo "======================================"
        echo "COMPARISON (V2 vs V1)"
        echo "======================================"
        echo "  Hashrate Difference: $DIFF H/s ($DIFF_PCT%)"
        echo "  $COMPARISON"
        echo "======================================"
    }

    # GitHub markdown summary
    GITHUB_SUMMARY() {
        echo ""
        echo "======================================"
        echo "GITHUB COPY-PASTE SUMMARY (Markdown)"
        echo "======================================"
        echo ""
        echo "### RandomX v2 Benchmark Results"
        echo ""
        echo "**CPU:** $CPU_MODEL"
        echo "**Config:** threads=$OPTIMAL_THREADS, affinity=$AFFINITY_MASK, init=$INIT_THREADS"
        echo ""
        echo "| Metric | V1 | V2 |"
        echo "|--------|----|----|"
        echo "| Crashes | $V1_SEGFAULTS/100 | $V2_SEGFAULTS/100 |"
        echo "| Avg Hashrate | $V1_AVG H/s | $V2_AVG H/s |"
        echo "| Std Dev | $V1_STDEV H/s | $V2_STDEV H/s |"
        echo "| Min | $V1_MIN H/s | $V2_MIN H/s |"
        echo "| Max | $V1_MAX H/s | $V2_MAX H/s |"
        echo ""
        echo "**Difference:** $DIFF H/s ($DIFF_PCT%) - $COMPARISON"
        echo ""
        echo "======================================"
    }

    # Print to screen and save to file
    OUTPUT_RESULTS | tee "$RESULTS_FILE"
    GITHUB_SUMMARY | tee -a "$RESULTS_FILE"

    # Also save raw hashrate data to results file
    echo "" >> "$RESULTS_FILE"
    echo "Raw V2 Hashrates:" >> "$RESULTS_FILE"
    cat "$V2_HASHRATES_FILE" >> "$RESULTS_FILE" 2>/dev/null
    echo "" >> "$RESULTS_FILE"
    echo "Raw V1 Hashrates:" >> "$RESULTS_FILE"
    cat "$V1_HASHRATES_FILE" >> "$RESULTS_FILE" 2>/dev/null

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
