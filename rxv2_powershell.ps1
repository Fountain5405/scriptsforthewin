#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Complete RandomX v2 Benchmark Script for Windows (PowerShell)

.DESCRIPTION
    - Clones and compiles RandomX from source (requires Git + CMake + Visual Studio)
    - Runs benchmark comparison between v1 and v2
    - Auto-detects optimal thread count and affinity
    - Note: RAPL power measurement is Linux-only; not available on Windows
    - Note: MSR optimizations require third-party tools on Windows (not included)

.PARAMETER Runs
    Number of benchmark runs per version (default: 2)

.PARAMETER Nonces
    Number of nonces per run (default: 1000000)

.PARAMETER OldCpu
    Old CPU mode (software AES, no AVX2)

.EXAMPLE
    .\rxv2_powershell.ps1
    .\rxv2_powershell.ps1 -Runs 10 -Nonces 500000
    .\rxv2_powershell.ps1 -OldCpu
#>

param(
    [int]$Runs = 2,
    [int]$Nonces = 1000000,
    [switch]$OldCpu
)

$ErrorActionPreference = "Stop"

# Constants
$RepoUrl = "https://github.com/SChernykh/RandomX.git"
$Branch = "v2"
$WorkDir = Join-Path $env:USERPROFILE "randomx_benchmark"

# RandomX VM operations per hash (from configuration.h)
# PROGRAM_SIZE x PROGRAM_ITERATIONS x PROGRAM_COUNT
$V1OpsPerHash = 256 * 2048 * 8   # = 4,194,304
$V2OpsPerHash = 384 * 2048 * 8   # = 6,291,456

##############################
# Helper Functions
##############################

function Write-Banner {
    param([string]$Text)
    Write-Host ""
    Write-Host "======================================" -ForegroundColor Cyan
    Write-Host $Text -ForegroundColor Cyan
    Write-Host "======================================" -ForegroundColor Cyan
}

function Test-Command {
    param([string]$Name)
    $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Format-Sci {
    param([double]$Value)
    if ($Value -eq 0) { return "N/A" }
    if ($Value -ge 1e9) { return "{0:F2}e9" -f ($Value / 1e9) }
    if ($Value -ge 1e6) { return "{0:F2}e6" -f ($Value / 1e6) }
    return "{0:F2}" -f $Value
}

##############################
# Dependency Detection
##############################

function Test-Dependencies {
    Write-Banner "Checking dependencies..."

    $missing = $false

    # Git
    if (Test-Command "git") {
        Write-Host "  git: OK" -ForegroundColor Green
    } else {
        Write-Host "  git: NOT FOUND" -ForegroundColor Red
        Write-Host "    Install from: https://git-scm.com/download/win"
        $missing = $true
    }

    # CMake
    if (Test-Command "cmake") {
        Write-Host "  cmake: OK" -ForegroundColor Green
    } else {
        Write-Host "  cmake: NOT FOUND" -ForegroundColor Red
        Write-Host "    Install from: https://cmake.org/download/"
        $missing = $true
    }

    # Visual Studio / MSVC (check for cl.exe or MSBuild)
    $hasCompiler = $false

    # Check for Visual Studio via vswhere
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) {
        $vsPath = & $vswhere -latest -property installationPath 2>$null
        if ($vsPath) {
            Write-Host "  Visual Studio: OK ($vsPath)" -ForegroundColor Green
            $hasCompiler = $true
        }
    }

    if (-not $hasCompiler) {
        # Check for cl.exe in PATH (Developer Command Prompt)
        if (Test-Command "cl") {
            Write-Host "  MSVC (cl.exe): OK" -ForegroundColor Green
            $hasCompiler = $true
        }
    }

    if (-not $hasCompiler) {
        # Check for MinGW
        if (Test-Command "g++") {
            Write-Host "  MinGW (g++): OK" -ForegroundColor Green
            $hasCompiler = $true
        }
    }

    if (-not $hasCompiler) {
        Write-Host "  C++ compiler: NOT FOUND" -ForegroundColor Red
        Write-Host "    Install Visual Studio with 'Desktop development with C++' workload"
        Write-Host "    Or install MinGW-w64"
        $missing = $true
    }

    if ($missing) {
        Write-Host ""
        Write-Host "Please install missing dependencies and re-run." -ForegroundColor Red
        exit 1
    }
}

##############################
# RandomX Repository Management
##############################

function Update-RandomX {
    Write-Banner "Checking RandomX repository..."

    $binaryPath = Join-Path $WorkDir "RandomX\build\Release\randomx-benchmark.exe"
    $repoDir = Join-Path $WorkDir "RandomX"

    if (-not (Test-Path $repoDir)) {
        Write-Host "  RandomX not found, will clone and build"
        return $false
    }

    Push-Location $repoDir
    try {
        Write-Host "  Fetching updates from origin..."
        git fetch origin 2>$null

        $localCommit = git rev-parse HEAD 2>$null
        $remoteCommit = git rev-parse "origin/$Branch" 2>$null

        Write-Host "  Local commit:  $($localCommit.Substring(0,7))"
        Write-Host "  Remote commit: $($remoteCommit.Substring(0,7))"

        if ($localCommit -ne $remoteCommit) {
            Write-Host "  Updates available, will pull and rebuild"
            git reset --hard "origin/$Branch"
            return $false
        } elseif (-not (Test-Path $binaryPath)) {
            Write-Host "  Binary not found, will build"
            return $false
        } else {
            Write-Host "  Already up to date"
            Write-Host "  Binary: $binaryPath"
            return $true
        }
    } finally {
        Pop-Location
    }
}

function Build-RandomX {
    Write-Banner "Building RandomX..."

    if (-not (Test-Path $WorkDir)) {
        New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
    }

    $repoDir = Join-Path $WorkDir "RandomX"

    if (-not (Test-Path $repoDir)) {
        Write-Host "Cloning RandomX repository..."
        git clone $RepoUrl (Join-Path $WorkDir "RandomX")
        Push-Location $repoDir
        git checkout $Branch
    } else {
        Push-Location $repoDir
    }

    try {
        $buildDir = Join-Path $repoDir "build"
        if (Test-Path $buildDir) {
            Remove-Item -Recurse -Force $buildDir
        }
        New-Item -ItemType Directory -Path $buildDir -Force | Out-Null

        Push-Location $buildDir
        try {
            # Detect compiler and configure accordingly
            if (Test-Command "g++") {
                Write-Host "Building with MinGW..."
                cmake -G "MinGW Makefiles" -DARCH=native ..
                mingw32-make -j $env:NUMBER_OF_PROCESSORS
            } else {
                Write-Host "Building with Visual Studio..."
                cmake -DARCH=native ..
                cmake --build . --config Release -- /m
            }

            $binary = Join-Path $buildDir "Release\randomx-benchmark.exe"
            if (-not (Test-Path $binary)) {
                # MinGW puts it directly in build/
                $binary = Join-Path $buildDir "randomx-benchmark.exe"
            }

            if (Test-Path $binary) {
                Write-Host "Build complete: $binary" -ForegroundColor Green
            } else {
                Write-Host "Build failed: binary not found" -ForegroundColor Red
                exit 1
            }
        } finally {
            Pop-Location
        }
    } finally {
        Pop-Location
    }
}

##############################
# CPU Detection
##############################

function Get-OptimalSettings {
    Write-Banner "Detecting optimal settings..."

    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $script:CpuModel = $cpu.Name.Trim()
    $logicalCpus = $cpu.NumberOfLogicalProcessors
    $physicalCores = $cpu.NumberOfCores

    # Get L3 cache size in MB
    $l3CacheKB = 0
    $caches = Get-CimInstance Win32_CacheMemory -ErrorAction SilentlyContinue |
              Where-Object { $_.Purpose -match "L3" -or $_.Level -eq 5 }
    if ($caches) {
        $l3CacheKB = ($caches | Measure-Object -Property MaxCacheSize -Sum).Sum
    }

    # Fallback: use processor's L3CacheSize property
    if ($l3CacheKB -eq 0 -and $cpu.L3CacheSize -gt 0) {
        $l3CacheKB = $cpu.L3CacheSize
    }

    $cacheMB = [math]::Max(1, [math]::Floor($l3CacheKB / 1024))
    $cacheType = "L3"

    if ($cacheMB -eq 0) {
        # Fall back to L2
        if ($cpu.L2CacheSize -gt 0) {
            $cacheMB = [math]::Max(1, [math]::Floor($cpu.L2CacheSize / 1024))
            $cacheType = "L2"
        } else {
            $cacheMB = $logicalCpus * 2
            $cacheType = "unknown"
        }
    }

    # Each RandomX thread needs 2MB of cache
    $maxThreadsByCache = [math]::Max(1, [math]::Floor($cacheMB / 2))
    $script:OptimalThreads = [math]::Min($logicalCpus, $maxThreadsByCache)
    $script:OptimalThreads = [math]::Max(1, $script:OptimalThreads)
    $script:InitThreads = $logicalCpus

    # Calculate affinity mask (use first N logical processors)
    $mask = [uint64]0
    for ($i = 0; $i -lt $script:OptimalThreads; $i++) {
        $mask = $mask -bor ([uint64]1 -shl $i)
    }
    $script:AffinityMask = "0x{0:X}" -f $mask

    Write-Host "System detected:"
    Write-Host "  CPU: $($script:CpuModel)"
    Write-Host "  Logical CPUs: $logicalCpus"
    Write-Host "  Physical cores: $physicalCores"
    Write-Host "  ${cacheType} Cache: ${cacheMB} MB"
    Write-Host "  Max threads by cache: $maxThreadsByCache"
    Write-Host "  Optimal mining threads: $($script:OptimalThreads)"
    Write-Host "  Init threads: $($script:InitThreads)"
    Write-Host "  Affinity mask: $($script:AffinityMask)"
}

##############################
# Large Pages
##############################

function Enable-LargePages {
    Write-Banner "Checking Large Pages support..."

    # Check if the current user has SeLockMemoryPrivilege
    $whoami = whoami /priv 2>$null
    if ($whoami -match "SeLockMemoryPrivilege.*Enabled") {
        Write-Host "  Large Pages: Enabled" -ForegroundColor Green
    } else {
        Write-Host "  Large Pages: Not configured or not enabled" -ForegroundColor Yellow
        Write-Host "  For best performance, enable 'Lock pages in memory' for your user:"
        Write-Host "    1. Run secpol.msc (Local Security Policy)"
        Write-Host "    2. Navigate to: Local Policies > User Rights Assignment"
        Write-Host "    3. Double-click 'Lock pages in memory'"
        Write-Host "    4. Add your user account"
        Write-Host "    5. Log out and back in"
        Write-Host "  Continuing without large pages..." -ForegroundColor Yellow
    }
}

##############################
# Benchmark
##############################

function Run-Benchmarks {
    Write-Banner "Running benchmarks..."

    # Find the binary
    $binary = Join-Path $WorkDir "RandomX\build\Release\randomx-benchmark.exe"
    if (-not (Test-Path $binary)) {
        $binary = Join-Path $WorkDir "RandomX\build\randomx-benchmark.exe"
    }
    if (-not (Test-Path $binary)) {
        Write-Host "ERROR: randomx-benchmark.exe not found" -ForegroundColor Red
        exit 1
    }

    # Build base arguments
    $baseArgs = @("--mine", "--jit", "--largePages",
                  "--threads", $script:OptimalThreads,
                  "--affinity", $script:AffinityMask,
                  "--init", $script:InitThreads,
                  "--nonces", $Nonces)

    if ($OldCpu) {
        $baseArgs += "--softAes"
    } else {
        $baseArgs += "--avx2"
    }

    $resultsFile = Join-Path $WorkDir "benchmark_results_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"

    # Storage for metrics
    $v2Hashrates = @()
    $v1Hashrates = @()
    $v2Times = @()
    $v1Times = @()
    $v2Crashes = 0
    $v1Crashes = 0
    $v2Success = 0
    $v1Success = 0

    Write-Host ""
    Write-Host "Binary: $binary"
    Write-Host "Base args: $($baseArgs -join ' ')"
    Write-Host "Results will be saved to: $resultsFile"
    Write-Host ""

    # --- V2 runs ---
    Write-Host "Testing with --v2 flag ($Runs runs)..."
    Write-Host ""

    for ($i = 1; $i -le $Runs; $i++) {
        Write-Host "--- Run $i/$Runs (v2) ---" -ForegroundColor Yellow
        $runArgs = $baseArgs + @("--v2")
        Write-Host "Command: $binary $($runArgs -join ' ')"

        $startTime = Get-Date

        try {
            $output = & $binary @runArgs 2>&1 | Out-String
            $exitCode = $LASTEXITCODE
            Write-Host $output
        } catch {
            $exitCode = 1
            $output = $_.Exception.Message
            Write-Host $output -ForegroundColor Red
        }

        $endTime = Get-Date
        $runtime = ($endTime - $startTime).TotalSeconds

        if ($exitCode -ne 0) {
            $v2Crashes++
            Write-Host ">>> Result: CRASH (exit code: $exitCode)" -ForegroundColor Red
        } else {
            $v2Success++

            # Extract hashrate
            if ($output -match "Performance:\s*([\d.]+)") {
                $hashrate = [double]$Matches[1]
                $v2Hashrates += $hashrate
                $v2Times += $runtime
                Write-Host ">>> Result: OK (Hashrate: $hashrate H/s)" -ForegroundColor Green
            } else {
                Write-Host ">>> Result: OK (could not parse hashrate)" -ForegroundColor Yellow
            }
        }
        Write-Host ""
    }

    Write-Host "V2 testing complete. Crashes: $v2Crashes / $Runs" -ForegroundColor Cyan
    Write-Host ""

    # --- V1 runs ---
    Write-Host "Testing without --v2 flag ($Runs runs)..."
    Write-Host ""

    for ($i = 1; $i -le $Runs; $i++) {
        Write-Host "--- Run $i/$Runs (v1) ---" -ForegroundColor Yellow
        Write-Host "Command: $binary $($baseArgs -join ' ')"

        $startTime = Get-Date

        try {
            $output = & $binary @baseArgs 2>&1 | Out-String
            $exitCode = $LASTEXITCODE
            Write-Host $output
        } catch {
            $exitCode = 1
            $output = $_.Exception.Message
            Write-Host $output -ForegroundColor Red
        }

        $endTime = Get-Date
        $runtime = ($endTime - $startTime).TotalSeconds

        if ($exitCode -ne 0) {
            $v1Crashes++
            Write-Host ">>> Result: CRASH (exit code: $exitCode)" -ForegroundColor Red
        } else {
            $v1Success++

            # Extract hashrate
            if ($output -match "Performance:\s*([\d.]+)") {
                $hashrate = [double]$Matches[1]
                $v1Hashrates += $hashrate
                $v1Times += $runtime
                Write-Host ">>> Result: OK (Hashrate: $hashrate H/s)" -ForegroundColor Green
            } else {
                Write-Host ">>> Result: OK (could not parse hashrate)" -ForegroundColor Yellow
            }
        }
        Write-Host ""
    }

    Write-Host "V1 testing complete. Crashes: $v1Crashes / $Runs" -ForegroundColor Cyan

    # --- Calculate results ---
    Display-Results -V2Hashrates $v2Hashrates -V1Hashrates $v1Hashrates `
                    -V2Times $v2Times -V1Times $v1Times `
                    -V2Crashes $v2Crashes -V1Crashes $v1Crashes `
                    -V2Success $v2Success -V1Success $v1Success `
                    -ResultsFile $resultsFile
}

function Get-Stats {
    param([double[]]$Values)

    if ($Values.Count -eq 0) {
        return @{ Avg = 0; StdDev = 0; Min = 0; Max = 0; Count = 0 }
    }

    $avg = ($Values | Measure-Object -Average).Average
    $min = ($Values | Measure-Object -Minimum).Minimum
    $max = ($Values | Measure-Object -Maximum).Maximum
    $count = $Values.Count

    $stddev = 0
    if ($count -gt 1) {
        $sumSqDiff = ($Values | ForEach-Object { ($_ - $avg) * ($_ - $avg) } |
                      Measure-Object -Sum).Sum
        $stddev = [math]::Sqrt($sumSqDiff / ($count - 1))
    }

    return @{
        Avg    = [math]::Round($avg, 2)
        StdDev = [math]::Round($stddev, 2)
        Min    = [math]::Round($min, 2)
        Max    = [math]::Round($max, 2)
        Count  = $count
    }
}

function Display-Results {
    param(
        [double[]]$V2Hashrates,
        [double[]]$V1Hashrates,
        [double[]]$V2Times,
        [double[]]$V1Times,
        [int]$V2Crashes,
        [int]$V1Crashes,
        [int]$V2Success,
        [int]$V1Success,
        [string]$ResultsFile
    )

    $v2Stats = Get-Stats $V2Hashrates
    $v1Stats = Get-Stats $V1Hashrates

    # VM+AES operations per second
    $v1Vmaes = if ($v1Stats.Avg -gt 0) { $v1Stats.Avg * $V1OpsPerHash } else { 0 }
    $v2Vmaes = if ($v2Stats.Avg -gt 0) { $v2Stats.Avg * $V2OpsPerHash } else { 0 }

    # Relative speed
    $v1RelSpeed = "100.00"
    $v2RelSpeed = if ($v1Stats.Avg -gt 0) {
        "{0:F2}" -f (($v2Stats.Avg / $v1Stats.Avg) * 100)
    } else { "N/A" }

    # Format large numbers
    $v1VmaesFmt = Format-Sci $v1Vmaes
    $v2VmaesFmt = Format-Sci $v2Vmaes

    # Power measurement not available on Windows
    $powerNote = "(power measurement requires Linux RAPL)"

    # --- Terminal output ---
    $output = @"

======================================
FINAL RESULTS
======================================
System: $($script:CpuModel)
Threads: $($script:OptimalThreads) | Affinity: $($script:AffinityMask) | Init: $($script:InitThreads)
Note: $powerNote

V2 (with --v2 flag):
  Crashes:       $V2Crashes / $Runs
  Success:       $V2Success / $Runs
  Avg Hashrate:  $($v2Stats.Avg) H/s
  Relative:      ${v2RelSpeed}%
  VM+AES/s:      $v2VmaesFmt

V1 (without --v2 flag):
  Crashes:       $V1Crashes / $Runs
  Success:       $V1Success / $Runs
  Avg Hashrate:  $($v1Stats.Avg) H/s
  Relative:      ${v1RelSpeed}%
  VM+AES/s:      $v1VmaesFmt

======================================
"@

    Write-Host $output

    # --- GitHub markdown summary ---
    $ghSummary = @"

======================================
GITHUB COPY-PASTE SUMMARY (Markdown)
======================================

### RandomX v2 Benchmark Results

**$($script:CpuModel)**

| Algorithm | Hashrate | Relative Speed | VM+AES/s |
|-----------|----------|----------------|----------|
| RandomX v1 | $($v1Stats.Avg) | ${v1RelSpeed}% | $v1VmaesFmt |
| RandomX v2 | $($v2Stats.Avg) | ${v2RelSpeed}% | $v2VmaesFmt |

**Config:** threads=$($script:OptimalThreads), affinity=$($script:AffinityMask), init=$($script:InitThreads)

**Stability:** V1 crashes: $V1Crashes/$Runs, V2 crashes: $V2Crashes/$Runs

---

<details>
<summary>Detailed Statistics</summary>

| Metric | V1 | V2 |
|--------|----|----|
| Successful runs | $($v1Stats.Count) | $($v2Stats.Count) |
| Hashrate (avg) | $($v1Stats.Avg) H/s | $($v2Stats.Avg) H/s |
| Hashrate (std dev) | $($v1Stats.StdDev) H/s | $($v2Stats.StdDev) H/s |
| Hashrate (min) | $($v1Stats.Min) H/s | $($v2Stats.Min) H/s |
| Hashrate (max) | $($v1Stats.Max) H/s | $($v2Stats.Max) H/s |

</details>

======================================
"@

    Write-Host $ghSummary

    # Save to file
    $fullOutput = $output + $ghSummary
    $fullOutput += "`n`nRaw V2 Hashrates:`n"
    $fullOutput += ($V2Hashrates -join "`n")
    $fullOutput += "`n`nRaw V1 Hashrates:`n"
    $fullOutput += ($V1Hashrates -join "`n")

    $fullOutput | Out-File -FilePath $ResultsFile -Encoding UTF8

    Write-Host "Results saved to: $ResultsFile" -ForegroundColor Green
}

##############################
# Main
##############################

function Main {
    Write-Banner "RandomX v2 Benchmark Suite (Windows)"
    Write-Host ""

    Test-Dependencies
    Enable-LargePages

    # Check for updates and build if needed
    if (-not (Update-RandomX)) {
        Build-RandomX
    }

    Get-OptimalSettings
    Run-Benchmarks

    Write-Host ""
    Write-Banner "Benchmark complete!"
}

Main
