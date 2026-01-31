<#
.SYNOPSIS
    Complete RandomX v2 Benchmark Script for Windows (PowerShell)

.DESCRIPTION
    - AUTO-DOWNLOADS portable CMake and MinGW (no installation required)
    - AUTO-DOWNLOADS Intel Power Gadget for power measurement (Intel CPUs only)
    - AUTO-DOWNLOADS WinRing0 for MSR optimizations (requires Admin)
    - Clones and compiles RandomX from source (requires Git)
    - Runs benchmark comparison between v1 and v2
    - Auto-detects optimal thread count and affinity
    - Measures CPU package power during benchmarks
    - Applies MSR optimizations for Intel/AMD CPUs

.PARAMETER Runs
    Number of benchmark runs per version (default: 2)

.PARAMETER Nonces
    Number of nonces per run (default: 1000000)

.PARAMETER OldCpu
    Old CPU mode (software AES, no AVX2)

.PARAMETER NoMsr
    Disable MSR optimizations

.EXAMPLE
    .\rxv2_powershell.ps1
    .\rxv2_powershell.ps1 -Runs 10 -Nonces 500000
    .\rxv2_powershell.ps1 -OldCpu
    .\rxv2_powershell.ps1 -NoMsr
#>

param(
    [int]$Runs = 2,
    [int]$Nonces = 1000000,
    [switch]$OldCpu,
    [switch]$NoMsr
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
    # Check PATH first
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $true }

    # Check portable tools
    if ($script:CMakeBin -and (Test-Path (Join-Path $script:CMakeBin "$Name.exe"))) {
        return $true
    }
    if ($script:MinGWBin -and (Test-Path (Join-Path $script:MinGWBin "$Name.exe"))) {
        return $true
    }
    return $false
}

function Get-PortableCommand {
    param([string]$Name)

    # Check PATH first
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    # Check portable tools
    if ($script:CMakeBin -and (Test-Path (Join-Path $script:CMakeBin "$Name.exe"))) {
        return Join-Path $script:CMakeBin "$Name.exe"
    }
    if ($script:MinGWBin -and (Test-Path (Join-Path $script:MinGWBin "$Name.exe"))) {
        return Join-Path $script:MinGWBin "$Name.exe"
    }
    return $null
}

function Format-Sci {
    param([double]$Value)
    if ($Value -eq 0) { return "N/A" }
    if ($Value -ge 1e9) { return "{0:F2}e9" -f ($Value / 1e9) }
    if ($Value -ge 1e6) { return "{0:F2}e6" -f ($Value / 1e6) }
    return "{0:F2}" -f $Value
}

##############################
# Portable Tools Management
##############################

$script:PortableDir = Join-Path $WorkDir "tools"
$script:CMakeBin = $null
$script:MinGWBin = $null
$script:IPGDir = $null
$script:IPGExe = $null
$script:HasPowerGadget = $false
$script:HasLargePages = $false
$script:MsrEnabled = -not $NoMsr
$script:MsrToolPath = $null
$script:MsrDriverInstalled = $false
$script:MsrBackupValues = @{}

function Install-PortableTools {
    Write-Banner "Setting up portable build tools..."

    if (-not (Test-Path $script:PortableDir)) {
        New-Item -ItemType Directory -Path $script:PortableDir -Force | Out-Null
    }

    # Check if already installed
    $cmakePath = Join-Path $script:PortableDir "cmake\bin\cmake.exe"
    $gccPath = Join-Path $script:PortableDir "mingw64\bin\gcc.exe"

    $needCMake = -not (Test-Path $cmakePath)
    $needMinGW = -not (Test-Path $gccPath)

    if (-not $needCMake -and -not $needMinGW) {
        Write-Host "  Portable tools already installed" -ForegroundColor Green
        $script:CMakeBin = Join-Path $script:PortableDir "cmake\bin"
        $script:MinGWBin = Join-Path $script:PortableDir "mingw64\bin"
        return
    }

    Write-Host ""
    Write-Host "  Downloading portable tools (this may take a minute)..." -ForegroundColor Yellow

    # Download CMake portable
    if ($needCMake) {
        Write-Host "  Downloading CMake..."
        $cmakeUrl = "https://github.com/Kitware/CMake/releases/download/v3.30.5/cmake-3.30.5-windows-x86_64.zip"
        $cmakeZip = Join-Path $script:PortableDir "cmake.zip"

        try {
            Invoke-WebRequest -Uri $cmakeUrl -OutFile $cmakeZip -UseBasicParsing
            Write-Host "    Extracting CMake..."
            Expand-Archive -Path $cmakeZip -DestinationPath $script:PortableDir -Force
            Remove-Item $cmakeZip -Force

            # Rename to simple "cmake" folder
            $extracted = Get-ChildItem $script:PortableDir -Directory | Where-Object { $_.Name -match "cmake-.*-windows" } | Select-Object -First 1
            if ($extracted) {
                $targetPath = Join-Path $script:PortableDir "cmake"
                if (Test-Path $targetPath) { Remove-Item $targetPath -Recurse -Force }
                Move-Item $extracted.FullName $targetPath -Force
            }

            Write-Host "    CMake installed" -ForegroundColor Green
        } catch {
            Write-Host "    Failed to download CMake: $_" -ForegroundColor Red
            exit 1
        }
    } else {
        Write-Host "  CMake: already installed" -ForegroundColor Green
    }

    # Download MinGW-w64
    if ($needMinGW) {
        Write-Host "  Downloading MinGW-w64..."

        # Try GitHub API first to find latest stable release URL dynamically
        $downloadSources = @()

        try {
            Write-Host "    Querying GitHub for latest WinLibs release..."
            $apiUrl = "https://api.github.com/repos/brechtsanders/winlibs_mingw/releases?per_page=20"
            $releases = Invoke-RestMethod -Uri $apiUrl -UseBasicParsing -ErrorAction Stop

            foreach ($rel in $releases) {
                $tag = $rel.tag_name
                if ($tag -match "snapshot") { continue }
                if ($tag -notmatch "posix") { continue }

                foreach ($asset in $rel.assets) {
                    if ($asset.name -match "x86_64" -and $asset.name.EndsWith(".zip") -and $asset.name -match "posix") {
                        $downloadSources += @{
                            Url  = $asset.browser_download_url
                            Name = "WinLibs ($tag)"
                        }
                        break
                    }
                }
                if ($downloadSources.Count -ge 2) { break }
            }

            if ($downloadSources.Count -gt 0) {
                Write-Host "    Found $($downloadSources.Count) release(s) via GitHub API" -ForegroundColor Green
            }
        } catch {
            Write-Host "    GitHub API query failed, using hardcoded URLs" -ForegroundColor Yellow
        }

        # Hardcoded fallback URLs (verified working as of Jan 2026)
        $downloadSources += @(
            @{
                Url  = "https://github.com/brechtsanders/winlibs_mingw/releases/download/15.2.0posix-13.0.0-ucrt-r5/winlibs-x86_64-posix-seh-gcc-15.2.0-mingw-w64ucrt-13.0.0-r5.zip"
                Name = "WinLibs (GCC 15.2.0 fallback)"
            },
            @{
                Url  = "https://github.com/brechtsanders/winlibs_mingw/releases/download/14.3.0posix-12.0.0-ucrt-r1/winlibs-x86_64-posix-seh-gcc-14.3.0-mingw-w64ucrt-12.0.0-r1.zip"
                Name = "WinLibs (GCC 14.3.0 fallback)"
            }
        )

        $success = $false
        $mingwZip = Join-Path $script:PortableDir "mingw.zip"

        foreach ($source in $downloadSources) {
            if ($success) { break }

            try {
                Write-Host "    Trying: $($source.Name)..."
                $ProgressPreference = 'SilentlyContinue'

                # Use WebClient with proper headers
                $webClient = New-Object System.Net.WebClient
                $webClient.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64)")
                $webClient.DownloadFile($source.Url, $mingwZip)

                $ProgressPreference = 'Continue'

                $fileInfo = Get-Item $mingwZip
                if ($fileInfo.Length -lt 5MB) {
                    Write-Host "      Download too small, trying next..." -ForegroundColor Yellow
                    Remove-Item $mingwZip -Force -ErrorAction SilentlyContinue
                    continue
                }

                Write-Host "      Downloaded: $([math]::Round($fileInfo.Length / 1MB, 1)) MB" -ForegroundColor Green
                Write-Host "      Extracting (this may take a few minutes)..."

                $mingwTemp = Join-Path $script:PortableDir "mingw_temp"
                if (Test-Path $mingwTemp) { Remove-Item $mingwTemp -Recurse -Force }
                New-Item -ItemType Directory -Path $mingwTemp -Force | Out-Null

                Add-Type -AssemblyName System.IO.Compression.FileSystem
                [System.IO.Compression.ZipFile]::ExtractToDirectory($mingwZip, $mingwTemp)

                # WinLibs structure: mingw64 is at the root
                $mingwExtracted = Join-Path $mingwTemp "mingw64"
                if (-not (Test-Path $mingwExtracted)) {
                    # Check subdirectories
                    $firstDir = Get-ChildItem $mingwTemp -Directory | Select-Object -First 1
                    if ($firstDir) {
                        $mingwExtracted = Join-Path $firstDir.FullName "mingw64"
                    }
                }

                # Final fallback - just use what we got
                if (-not (Test-Path $mingwExtracted)) {
                    $allDirs = Get-ChildItem $mingwTemp -Directory -Recurse
                    $mingwBin = $allDirs | Where-Object { (Test-Path (Join-Path $_.FullName "gcc.exe")) } | Select-Object -First 1
                    if ($mingwBin) {
                        $mingwExtracted = $mingwBin.Parent.FullName
                    } else {
                        throw "Could not find MinGW binaries in archive"
                    }
                }

                # Copy to target
                $targetPath = Join-Path $script:PortableDir "mingw64"
                if (Test-Path $targetPath) { Remove-Item $targetPath -Recurse -Force }
                New-Item -ItemType Directory -Path $targetPath -Force | Out-Null

                if (Test-Path (Join-Path $mingwExtracted "bin\gcc.exe")) {
                    Copy-Item "$mingwExtracted\*" $targetPath -Recurse -Force
                } else {
                    throw "gcc.exe not found at expected location"
                }

                # Cleanup
                Remove-Item $mingwZip -Force -ErrorAction SilentlyContinue
                Remove-Item $mingwTemp -Recurse -Force -ErrorAction SilentlyContinue

                # Verify
                $gccPath = Join-Path $targetPath "bin\gcc.exe"
                if (Test-Path $gccPath) {
                    Write-Host "    MinGW installed successfully!" -ForegroundColor Green
                    $success = $true
                } else {
                    throw "Verification failed"
                }

            } catch {
                Write-Host "      Failed: $_" -ForegroundColor Yellow
                Remove-Item $mingwZip -Force -ErrorAction SilentlyContinue
                if (Test-Path (Join-Path $script:PortableDir "mingw64")) {
                    Remove-Item (Join-Path $script:PortableDir "mingw64") -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }

        if (-not $success) {
            Write-Host ""
            Write-Host "  All automatic download attempts failed!" -ForegroundColor Red
            Write-Host ""
            Write-Host "  Quick fix - Choose one option:" -ForegroundColor Yellow
            Write-Host ""
            Write-Host "  Option 1 - Install MSYS2 (Recommended):" -ForegroundColor Cyan
            Write-Host "    1. Download: https://github.com/msys2/msys2-installer/releases" -ForegroundColor White
            Write-Host "    2. Run MSYS2 shell and execute:" -ForegroundColor White
            Write-Host "       pacman -S mingw-w64-x86_64-gcc mingw-w64-x86_64-cmake" -ForegroundColor White
            Write-Host "    3. Add C:\msys64\mingw64\bin to your PATH" -ForegroundColor White
            Write-Host ""
            Write-Host "  Option 2 - Manual MinGW download:" -ForegroundColor Cyan
            Write-Host "    1. Download: https://github.com/brechtsanders/winlibs_mingw/releases" -ForegroundColor White
            Write-Host "    2. Extract to: $script:PortableDir\mingw64" -ForegroundColor White
            Write-Host ""
            Write-Host "  After manual installation, run this script again." -ForegroundColor Yellow
            exit 1
        }
    } else {
        Write-Host "  MinGW: already installed" -ForegroundColor Green
    }

    $script:CMakeBin = Join-Path $script:PortableDir "cmake\bin"
    $script:MinGWBin = Join-Path $script:PortableDir "mingw64\bin"

    Write-Host ""
    Write-Host "  Portable tools ready!" -ForegroundColor Green
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

    if ($missing) {
        Write-Host ""
        Write-Host "Please install Git and re-run." -ForegroundColor Red
        exit 1
    }

    # Install portable CMake and MinGW
    Install-PortableTools

    Write-Host "  All dependencies ready!" -ForegroundColor Green
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
            # Get portable tool paths
            $cmakeExe = Get-PortableCommand "cmake"
            $mingwMake = Join-Path $script:MinGWBin "mingw32-make.exe"

            # Add MinGW to PATH for this session
            $env:PATH = "$script:MinGWBin;$env:PATH"

            Write-Host "Building with MinGW (portable)..."
            & $cmakeExe -G "MinGW Makefiles" -DARCH=native ..
            & $mingwMake -j $env:NUMBER_OF_PROCESSORS

            $binary = Join-Path $buildDir "randomx-benchmark.exe"

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
    if ($whoami -match "SeLockMemoryPrivilege") {
        $script:HasLargePages = $true
        Write-Host "  Large Pages: Enabled" -ForegroundColor Green
        return
    }

    # Not enabled yet - attempt to grant the privilege automatically
    Write-Host "  Large Pages: Not configured" -ForegroundColor Yellow
    Write-Host "  Attempting to enable 'Lock pages in memory' policy..." -ForegroundColor Yellow

    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

    try {
        # Export current security policy
        $tempCfg = Join-Path $env:TEMP "secpol_export.cfg"
        $tempDb = Join-Path $env:TEMP "secpol_export.sdb"
        secedit /export /cfg $tempCfg /quiet

        # Read the exported policy
        $content = Get-Content $tempCfg -Raw

        if ($content -match "(SeLockMemoryPrivilege\s*=\s*)(.*)") {
            $existing = $Matches[2].Trim()
            # Add current user's SID if not already present
            $currentSid = ([System.Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
            if ($existing -notmatch [regex]::Escape($currentSid)) {
                $newValue = "$existing,*$currentSid"
                $content = $content -replace "SeLockMemoryPrivilege\s*=\s*.*", "SeLockMemoryPrivilege = $newValue"
            } else {
                Write-Host "  SID already in policy but privilege not active (reboot needed)" -ForegroundColor Yellow
                $script:HasLargePages = $false
                Remove-Item $tempCfg -Force -ErrorAction SilentlyContinue
                Write-Host ""
                Write-Host "  Please reboot your computer, then run this script again." -ForegroundColor Red
                Write-Host "  The 'Lock pages in memory' policy was previously configured but requires a reboot." -ForegroundColor Red
                exit 1
            }
        } else {
            # SeLockMemoryPrivilege line doesn't exist, add it under [Privilege Rights]
            $currentSid = ([System.Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
            $content = $content -replace "(\[Privilege Rights\])", "`$1`r`nSeLockMemoryPrivilege = *$currentSid"
        }

        # Write modified policy
        Set-Content $tempCfg -Value $content

        # Import the modified policy
        secedit /configure /db $tempDb /cfg $tempCfg /quiet

        # Cleanup temp files
        Remove-Item $tempCfg -Force -ErrorAction SilentlyContinue
        Remove-Item $tempDb -Force -ErrorAction SilentlyContinue
        # secedit also creates a log file
        $seceditLog = Join-Path $env:TEMP "secpol_export.log"
        Remove-Item $seceditLog -Force -ErrorAction SilentlyContinue

        Write-Host "  'Lock pages in memory' policy granted to: $currentUser" -ForegroundColor Green
        Write-Host ""
        Write-Host "  *** A reboot is required for the policy to take effect. ***" -ForegroundColor Red
        Write-Host ""

        $response = Read-Host "  Reboot now? (y/n)"
        if ($response -match "^[yY]") {
            Write-Host "  Rebooting in 10 seconds... (Ctrl+C to cancel)" -ForegroundColor Yellow
            Start-Sleep -Seconds 10
            Restart-Computer -Force
        } else {
            Write-Host "  Please reboot manually, then run this script again." -ForegroundColor Yellow
            exit 0
        }

    } catch {
        Write-Host "  Failed to set policy automatically: $_" -ForegroundColor Red
        Write-Host ""
        Write-Host "  Manual steps to enable Large Pages:" -ForegroundColor Yellow
        Write-Host "    1. Press Win+R, type secpol.msc, press Enter"
        Write-Host "    2. Navigate to: Local Policies > User Rights Assignment"
        Write-Host "    3. Double-click 'Lock pages in memory'"
        Write-Host "    4. Click 'Add User or Group', add your user account"
        Write-Host "    5. Click OK, then reboot your computer"
        Write-Host ""
        Write-Host "  After rebooting, run this script again." -ForegroundColor Yellow
        exit 1
    }
}

##############################
# Intel Power Gadget
##############################

function Install-IntelPowerGadget {
    Write-Banner "Setting up Intel Power Gadget..."

    # Check for Intel CPU
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    if ($cpu.Manufacturer -notmatch "Intel") {
        Write-Host "  Not an Intel CPU - power measurement unavailable" -ForegroundColor Yellow
        return
    }

    # Check for already installed IPG
    $ipgPaths = @(
        "${env:ProgramFiles}\Intel\Power Gadget 3.5",
        "${env:ProgramFiles}\Intel\Power Gadget 3.6",
        "${env:ProgramFiles}\Intel\Power Gadget",
        "${env:ProgramFiles(x86)}\Intel\Power Gadget 3.5",
        "${env:ProgramFiles(x86)}\Intel\Power Gadget 3.6",
        "${env:ProgramFiles(x86)}\Intel\Power Gadget",
        (Join-Path $script:PortableDir "IntelPowerGadget")
    )

    foreach ($path in $ipgPaths) {
        $exe = Join-Path $path "PowerLog3.exe"
        if (Test-Path $exe) {
            $script:IPGDir = $path
            $script:IPGExe = $exe
            $script:HasPowerGadget = $true
            Write-Host "  Intel Power Gadget: Found at $path" -ForegroundColor Green
            return
        }
    }

    # Try to download and install portable version
    Write-Host "  Intel Power Gadget not found" -ForegroundColor Yellow
    Write-Host "  Attempting to download portable version..." -ForegroundColor Yellow

    $ipgPortableDir = Join-Path $script:PortableDir "IntelPowerGadget"
    $ipgZip = Join-Path $script:PortableDir "IPG.zip"

    try {
        # IPG 3.6 download URL (direct download link)
        $ipgUrl = "https://github.com/intel/Intel-Power-Gadget/releases/download/V3.6.0/Intel.Power.Gadget.3.6.0.zip"

        Write-Host "  Downloading Intel Power Gadget..."
        Invoke-WebRequest -Uri $ipgUrl -OutFile $ipgZip -UseBasicParsing

        Write-Host "  Extracting..."
        $ipgTemp = Join-Path $script:PortableDir "ipg_temp"
        if (Test-Path $ipgTemp) { Remove-Item $ipgTemp -Recurse -Force }
        New-Item -ItemType Directory -Path $ipgTemp -Force | Out-Null
        Expand-Archive -Path $ipgZip -DestinationPath $ipgTemp -Force

        # Find the PowerLog3.exe in extracted content
        $extractedExe = Get-ChildItem $ipgTemp -Recurse -Filter "PowerLog3.exe" | Select-Object -First 1

        if ($extractedExe) {
            # Move to portable directory
            if (Test-Path $ipgPortableDir) { Remove-Item $ipgPortableDir -Recurse -Force }
            New-Item -ItemType Directory -Path $ipgPortableDir -Force | Out-Null

            # Copy all needed files
            $ipgBinDir = $extractedExe.DirectoryName
            Copy-Item "$ipgBinDir\*" -Destination $ipgPortableDir -Recurse -Force

            $script:IPGDir = $ipgPortableDir
            $script:IPGExe = Join-Path $ipgPortableDir "PowerLog3.exe"

            if (Test-Path $script:IPGExe) {
                $script:HasPowerGadget = $true
                Write-Host "  Intel Power Gadget: Installed portably" -ForegroundColor Green
            } else {
                Write-Host "  Intel Power Gadget: Failed to extract properly" -ForegroundColor Red
            }
        } else {
            Write-Host "  Intel Power Gadget: PowerLog3.exe not found in archive" -ForegroundColor Red
            Write-Host "  Please install manually from: https://www.intel.com/content/www/us/en/developer/docs/energy-developer-kit/intel-power-gadget.html" -ForegroundColor Yellow
        }

        # Cleanup
        Remove-Item $ipgZip -Force -ErrorAction SilentlyContinue
        Remove-Item $ipgTemp -Recurse -Force -ErrorAction SilentlyContinue

    } catch {
        Write-Host "  Failed to download Intel Power Gadget: $_" -ForegroundColor Yellow
        Write-Host "  Power measurement will be skipped" -ForegroundColor Yellow
        Write-Host "  Manual install: https://www.intel.com/content/www/us/en/developer/docs/energy-developer-kit/intel-power-gadget.html" -ForegroundColor Yellow
    }

    if ($script:HasPowerGadget) {
        Write-Host "  Power measurement enabled!" -ForegroundColor Green
    } else {
        Write-Host "  Continuing without power measurement..." -ForegroundColor Yellow
    }
}

function Start-PowerLog {
    param([string]$LogFile)

    if (-not $script:HasPowerGadget -or -not $script:IPGExe) {
        return $null
    }

    try {
        # Start PowerLog3 in background
        $process = Start-Process -FilePath $script:IPGExe `
            -ArgumentList "-duration", "3600", "-file", $LogFile `
            -WindowStyle Hidden -PassThru

        return $process
    } catch {
        Write-Host "    Warning: Could not start power logging: $_" -ForegroundColor Yellow
        return $null
    }
}

function Stop-PowerLog {
    param([System.Diagnostics.Process]$Process)

    if ($Process -and -not $Process.HasExited) {
        try {
            $Process.Kill()
            $Process.WaitForExit(5000)
        } catch {
            # Ignore errors when stopping
        }
    }
}

function Get-PowerStats {
    param([string]$LogFile)

    if (-not (Test-Path $LogFile)) {
        return @{ AvgPower = 0; MaxPower = 0; Energy = 0 }
    }

    try {
        $csv = Import-Csv $LogFile

        # Power column is usually "Processor Power_0(Watt)" or similar
        $powerColumn = $csv[0].PSObject.Properties.Name |
                       Where-Object { $_ -match "Power.*Watt" } |
                       Select-Object -First 1

        if (-not $powerColumn) {
            return @{ AvgPower = 0; MaxPower = 0; Energy = 0 }
        }

        $powers = $csv | ForEach-Object { [double]::$_.$powerColumn }

        $avgPower = ($powers | Measure-Object -Average).Average
        $maxPower = ($powers | Measure-Object -Maximum).Maximum

        # Energy = avg power * time (hours) for kWh, or just avg power for display
        # We'll use Joules = avg power * duration in seconds
        $duration = $powers.Count * 0.1  # IPG samples every 100ms roughly
        $energyJoules = $avgPower * $duration

        return @{
            AvgPower = [math]::Round($avgPower, 2)
            MaxPower = [math]::Round($maxPower, 2)
            Energy = [math]::Round($energyJoules, 0)
        }
    } catch {
        return @{ AvgPower = 0; MaxPower = 0; Energy = 0 }
    }
}

function Format-Power {
    param([double]$Watts)

    if ($Watts -eq 0) { return "N/A" }
    if ($Watts -ge 1000) {
        return "{0:F2} kW" -f ($Watts / 1000)
    }
    return "{0:F2} W" -f $Watts
}

##############################
# MSR Optimizations (WinRing0)
##############################

function Test-Admin {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Install-MSRTool {
    Write-Banner "Setting up MSR access..."

    if (-not $script:MsrEnabled) {
        Write-Host "  MSR optimizations disabled (-NoMsr flag)" -ForegroundColor Yellow
        return
    }

    if (-not (Test-Admin)) {
        Write-Host "  MSR optimizations require Administrator privileges" -ForegroundColor Yellow
        Write-Host "  Please run PowerShell as Administrator" -ForegroundColor Yellow
        Write-Host "  Continuing without MSR optimizations..." -ForegroundColor Yellow
        $script:MsrEnabled = $false
        return
    }

    $msrDir = Join-Path $script:PortableDir "msr"
    if (-not (Test-Path $msrDir)) {
        New-Item -ItemType Directory -Path $msrDir -Force | Out-Null
    }

    # Check if msr-cmd is already installed
    $msrTool = Join-Path $msrDir "msr-cmd.exe"

    if (Test-Path $msrTool) {
        $script:MsrToolPath = $msrTool
        Write-Host "  MSR tool found at: $msrTool" -ForegroundColor Green
        return
    }

    # Download cocafe/msr-utility (WinRing0-based wrmsr equivalent for Windows)
    # Releases are .7z only, so we need 7-Zip to extract
    Write-Host "  Downloading MSR tool (cocafe/msr-utility)..." -ForegroundColor Yellow

    try {
        $msr7z = Join-Path $msrDir "msr-cmd.7z"

        # Get latest release URL via GitHub API
        $msrUrl = $null
        try {
            $releases = Invoke-RestMethod -Uri "https://api.github.com/repos/cocafe/msr-utility/releases?per_page=3" -UseBasicParsing -ErrorAction Stop
            foreach ($rel in $releases) {
                foreach ($asset in $rel.assets) {
                    if ($asset.name -match "msr-cmd.*\.7z") {
                        $msrUrl = $asset.browser_download_url
                        Write-Host "    Found release: $($asset.name)" -ForegroundColor Green
                        break
                    }
                }
                if ($msrUrl) { break }
            }
        } catch {
            Write-Host "    GitHub API failed, using hardcoded URL" -ForegroundColor Yellow
        }

        # Fallback URL
        if (-not $msrUrl) {
            $msrUrl = "https://github.com/cocafe/msr-utility/releases/download/20230811/msr-cmd_mingw.7z"
        }

        Write-Host "    Downloading msr-cmd..."
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $msrUrl -OutFile $msr7z -UseBasicParsing -ErrorAction Stop
        $ProgressPreference = 'Continue'

        # Need 7-Zip to extract .7z files
        # Check for system 7-Zip first
        $sevenZip = $null
        $sevenZipPaths = @(
            "${env:ProgramFiles}\7-Zip\7z.exe",
            "${env:ProgramFiles(x86)}\7-Zip\7z.exe"
        )
        foreach ($path in $sevenZipPaths) {
            if (Test-Path $path) {
                $sevenZip = $path
                break
            }
        }

        # If no system 7-Zip, download standalone 7za.exe (console version, ~1MB)
        if (-not $sevenZip) {
            Write-Host "    7-Zip not found, downloading standalone extractor..."
            $sevenZaDir = Join-Path $script:PortableDir "7zip"
            $sevenZaExe = Join-Path $sevenZaDir "7za.exe"

            if (-not (Test-Path $sevenZaExe)) {
                if (-not (Test-Path $sevenZaDir)) {
                    New-Item -ItemType Directory -Path $sevenZaDir -Force | Out-Null
                }

                # 7-Zip Extra (standalone console version)
                $sevenZipUrl = "https://www.7-zip.org/a/7z2409-extra.7z"
                # Since we can't extract .7z without 7-Zip, use the .zip distribution instead
                # 7-Zip provides a standalone 7za.exe in the "extra" package
                # Alternative: download from a direct exe source
                $sevenZipZipUrl = "https://github.com/nicehash/NiceHashQuickMiner/raw/main/checksums/7za.exe"

                # Try multiple sources for standalone 7za.exe
                $sevenZaSources = @(
                    "https://raw.githubusercontent.com/nicehash/NiceHashQuickMiner/main/checksums/7za.exe",
                    "https://github.com/nicehash/NiceHashQuickMiner/raw/main/checksums/7za.exe"
                )

                $downloaded = $false
                foreach ($src in $sevenZaSources) {
                    try {
                        $ProgressPreference = 'SilentlyContinue'
                        Invoke-WebRequest -Uri $src -OutFile $sevenZaExe -UseBasicParsing -ErrorAction Stop
                        $ProgressPreference = 'Continue'

                        if ((Get-Item $sevenZaExe).Length -gt 100KB) {
                            $downloaded = $true
                            Write-Host "    7za.exe downloaded" -ForegroundColor Green
                            break
                        }
                    } catch {
                        continue
                    }
                }

                if (-not $downloaded) {
                    throw "Could not download 7za.exe for extraction"
                }
            }

            $sevenZip = $sevenZaExe
        }

        # Extract the msr-cmd archive
        Write-Host "    Extracting msr-cmd..."
        $msrTemp = Join-Path $msrDir "temp"
        if (Test-Path $msrTemp) { Remove-Item $msrTemp -Recurse -Force }
        New-Item -ItemType Directory -Path $msrTemp -Force | Out-Null

        & $sevenZip x $msr7z "-o$msrTemp" -y 2>&1 | Out-Null

        # Find msr-cmd.exe in extracted files
        $extracted = Get-ChildItem $msrTemp -Recurse -Filter "msr-cmd.exe" | Select-Object -First 1

        if ($extracted) {
            # Copy msr-cmd.exe and any companion files (WinRing0 driver/dll)
            $srcDir = $extracted.DirectoryName
            Copy-Item "$srcDir\*" -Destination $msrDir -Recurse -Force -ErrorAction SilentlyContinue
            Copy-Item $extracted.FullName -Destination $msrTool -Force

            $script:MsrToolPath = $msrTool
            Write-Host "  MSR tool installed: $msrTool" -ForegroundColor Green
        } else {
            # Try finding any exe with 'msr' in the name
            $altExe = Get-ChildItem $msrTemp -Recurse -Filter "*.exe" | Where-Object { $_.Name -match "msr" } | Select-Object -First 1
            if ($altExe) {
                $srcDir = $altExe.DirectoryName
                Copy-Item "$srcDir\*" -Destination $msrDir -Recurse -Force -ErrorAction SilentlyContinue
                Copy-Item $altExe.FullName -Destination $msrTool -Force
                $script:MsrToolPath = $msrTool
                Write-Host "  MSR tool installed: $msrTool" -ForegroundColor Green
            } else {
                throw "msr-cmd.exe not found in archive"
            }
        }

        # Cleanup
        Remove-Item $msr7z -Force -ErrorAction SilentlyContinue
        Remove-Item $msrTemp -Recurse -Force -ErrorAction SilentlyContinue

    } catch {
        Write-Host "  MSR tool setup failed: $_" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  For MSR optimizations, you can:" -ForegroundColor Yellow
        Write-Host "    1. Install 7-Zip, then re-run this script" -ForegroundColor Cyan
        Write-Host "    2. Download msr-cmd manually from: https://github.com/cocafe/msr-utility/releases" -ForegroundColor Cyan
        Write-Host "       Extract to: $msrDir" -ForegroundColor Cyan
        Write-Host "    3. Use -NoMsr flag to skip MSR optimizations" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  Continuing without MSR optimizations..." -ForegroundColor Yellow
        $script:MsrEnabled = $false
    }
}

function Get-CPUBrand {
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    if ($cpu.Manufacturer -match "AMD") {
        return "AMD"
    } elseif ($cpu.Manufacturer -match "Intel") {
        return "Intel"
    }
    return "Unknown"
}

function Get-AMDZenGeneration {
    $cpu = Get-WmiObject Win32_Processor | Select-Object -First 1

    # Get CPU family and model from registry or WMI
    $registryPath = "HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0"
    if (Test-Path $registryPath) {
        $family = (Get-ItemProperty $registryPath).Identifier
        if ($family -match "Family ([0-9]+)") {
            $fam = [int]$Matches[1]
            if ($fam -eq 25) { return "Zen3" }  # Family 25h = Zen3/Zen4
            if ($fam -eq 26) { return "Zen5" }  # Family 26h = Zen5
            if ($fam -eq 23) { return "Zen1/Zen2" }  # Family 17h = Zen1/Zen2
        }
    }

    # Fallback: check CPU name
    $cpuName = $cpu.Name
    if ($cpuName -match "Ryzen\s*(\d+)") {
        $gen = $Matches[1]
        if ($gen -ge 9000) { return "Zen5" }
        if ($gen -ge 7000) { return "Zen4" }
        if ($gen -ge 5000) { return "Zen3" }
        if ($gen -ge 3000) { return "Zen2" }
        if ($gen -ge 1000) { return "Zen1" }
    }

    return "Unknown"
}

function Show-MSRInstructions {
    Write-Banner "MSR Optimization Instructions"

    $brand = Get-CPUBrand

    if ($brand -eq "Intel") {
        Write-Host "For Intel CPUs, disable hardware prefetchers:" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "Option 1 - Throttlestop (Recommended):"
        Write-Host "  1. Download: https://www.techpowerup.com/download/techpowerup-throttlestop/"
        Write-Host "  2. Open Throttlestop, go to Options"
        Write-Host "  3. Check 'Disable Turbo' and set multiplier to max non-turbo"
        Write-Host "  4. In 'TPU' section, disable prefetchers"
        Write-Host ""
        Write-Host "Option 2 - RWEverything:"
        Write-Host "  1. Download: https://rweverywhere.com/"
        Write-Host "  2. Use: RW.exe -Command=WriteMSR -Addr=0x1A4 -Value=0xF"
        Write-Host "     (This disables prefetchers - MSR 0x1a4 = 0xf)"
        Write-Host ""
    } elseif ($brand -eq "AMD") {
        $zen = Get-AMDZenGeneration
        Write-Host "For AMD $zen CPUs:" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "Option 1 - RyzenAdj (for Ryzen):"
        Write-Host "  1. Download: https://github.com/FlyGoat/RyzenAdj/releases"
        Write-Host "  2. Run: ryzenadj --max-performance"
        Write-Host ""
        Write-Host "Option 2 - CPU-Tweaker:"
        Write-Host "  1. Download: https://www.cpu-tweaker.com/"
        Write-Host "  2. Apply RandomX preset if available"
        Write-Host ""
        Write-Host "Option 3 - BIOS Settings:"
        Write-Host "  - Disable Global C-States"
        Write-Host "  - Set CPPC to Preferred Cores"
        Write-Host "  - Enable Precision Boost"
        Write-Host ""
    }

    Write-Host "After applying MSR tweaks, run this script with -NoMsr flag"
    Write-Host "to skip MSR setup and proceed directly to benchmarks."
}

function Write-MSR {
    param(
        [string]$Register,
        [uint64]$Value
    )

    if (-not $script:MsrToolPath) {
        return $false
    }

    try {
        $regHex = "0x$Register"
        # msr-cmd requires the 64-bit value split into EDX (upper 32 bits) and EAX (lower 32 bits)
        $edx = [uint32](($Value -shr 32) -band 0xFFFFFFFF)
        $eax = [uint32]($Value -band 0xFFFFFFFF)
        $edxHex = "0x$($edx.ToString('x8'))"
        $eaxHex = "0x$($eax.ToString('x8'))"

        # msr-cmd syntax: msr-cmd.exe -a write <register> <edx> <eax>
        $output = & $script:MsrToolPath -a write $regHex $edxHex $eaxHex 2>&1
        return $?
    } catch {
        return $false
    }
}

function Apply-MSROptimizations {
    if (-not $script:MsrEnabled) {
        return
    }

    if ($script:MsrToolPath) {
        $brand = Get-CPUBrand

        Write-Host ""
        Write-Host "Applying MSR optimizations..." -ForegroundColor Yellow

        if ($brand -eq "Intel") {
            Write-Host "  Intel CPU detected - disabling prefetchers (MSR 0x1a4 = 0xf)"
            if (Write-MSR -Register "1a4" -Value 0xf) {
                Write-Host "  MSR 0x1a4 set to 0xf (prefetchers disabled)" -ForegroundColor Green
                $script:MsrDriverInstalled = $true
            } else {
                Write-Host "  Failed to write MSR - driver may not be loaded" -ForegroundColor Yellow
                Show-MSRInstructions
                $script:MsrEnabled = $false
            }

        } elseif ($brand -eq "AMD") {
            $zen = Get-AMDZenGeneration
            Write-Host "  AMD $zen detected"

            # AMD MSR values from Linux script
            $success = $true

            if ($zen -eq "Zen4") {
                Write-Host "  Applying Zen4 MSR optimizations..."
                $success = $success -and (Write-MSR -Register "c0011020" -Value 0x4400000000000)
                $success = $success -and (Write-MSR -Register "c0011021" -Value 0x4000000000040)
                $success = $success -and (Write-MSR -Register "c0011022" -Value 0x8680000401570000)
                $success = $success -and (Write-MSR -Register "c001102b" -Value 0x2040cc10)
            } elseif ($zen -eq "Zen5") {
                Write-Host "  Applying Zen5 MSR optimizations..."
                $success = $success -and (Write-MSR -Register "c0011020" -Value 0x4400000000000)
                $success = $success -and (Write-MSR -Register "c0011021" -Value 0x4000000000040)
                $success = $success -and (Write-MSR -Register "c0011022" -Value 0x8680000401570000)
                $success = $success -and (Write-MSR -Register "c001102b" -Value 0x2040cc10)
            } elseif ($zen -eq "Zen3") {
                Write-Host "  Applying Zen3 MSR optimizations..."
                $success = $success -and (Write-MSR -Register "c0011020" -Value 0x4480000000000)
                $success = $success -and (Write-MSR -Register "c0011021" -Value 0x1c000200000040)
                $success = $success -and (Write-MSR -Register "c0011022" -Value 0xc000000401570000)
                $success = $success -and (Write-MSR -Register "c001102b" -Value 0x2000cc10)
            } else {
                Write-Host "  Applying Zen1/Zen2 MSR optimizations..."
                $success = $success -and (Write-MSR -Register "c0011020" -Value 0)
                $success = $success -and (Write-MSR -Register "c0011021" -Value 0x40)
                $success = $success -and (Write-MSR -Register "c0011022" -Value 0x1510000)
                $success = $success -and (Write-MSR -Register "c001102b" -Value 0x2000cc16)
            }

            if ($success) {
                Write-Host "  AMD MSR optimizations applied!" -ForegroundColor Green
                $script:MsrDriverInstalled = $true
            } else {
                Write-Host "  Failed to apply all MSR settings" -ForegroundColor Yellow
                Show-MSRInstructions
                $script:MsrEnabled = $false
            }

        } else {
            Write-Host "  Unknown CPU type - MSR optimizations not applied" -ForegroundColor Yellow
            Show-MSRInstructions
        }
    } else {
        # No MSR tool available - show instructions
        Show-MSRInstructions
    }
}

##############################
# Benchmark
##############################

function Run-Benchmarks {
    Write-Banner "Running benchmarks..."

    # Find the binary (MinGW puts it in build/, VS in build/Release/)
    $binary = Join-Path $WorkDir "RandomX\build\randomx-benchmark.exe"
    if (-not (Test-Path $binary)) {
        $binary = Join-Path $WorkDir "RandomX\build\Release\randomx-benchmark.exe"
    }
    if (-not (Test-Path $binary)) {
        Write-Host "ERROR: randomx-benchmark.exe not found" -ForegroundColor Red
        exit 1
    }

    # Build base arguments
    $baseArgs = @("--mine", "--jit",
                  "--threads", $script:OptimalThreads,
                  "--affinity", $script:AffinityMask,
                  "--init", $script:InitThreads,
                  "--nonces", $Nonces)

    if ($script:HasLargePages) {
        $baseArgs += "--largePages"
    }

    if ($OldCpu) {
        $baseArgs += "--softAes"
    } else {
        $baseArgs += "--avx2"
    }

    $resultsFile = Join-Path $WorkDir "benchmark_results_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
    $powerLogDir = Join-Path $WorkDir "power_logs"

    if ($script:HasPowerGadget) {
        if (-not (Test-Path $powerLogDir)) {
            New-Item -ItemType Directory -Path $powerLogDir -Force | Out-Null
        }
    }

    # Storage for metrics
    $v2Hashrates = @()
    $v1Hashrates = @()
    $v2Times = @()
    $v1Times = @()
    $v2Crashes = 0
    $v1Crashes = 0
    $v2Success = 0
    $v1Success = 0
    $v2Powers = @()  # Avg power per run
    $v1Powers = @()  # Avg power per run

    Write-Host ""
    Write-Host "Binary: $binary"
    Write-Host "Base args: $($baseArgs -join ' ')"
    Write-Host "Results will be saved to: $resultsFile"
    if ($script:HasPowerGadget) {
        Write-Host "Power measurement: ENABLED"
    } else {
        Write-Host "Power measurement: DISABLED (Intel CPU + IPG required)"
    }
    Write-Host ""

    # --- V2 runs ---
    Write-Host "Testing with --v2 flag ($Runs runs)..."
    Write-Host ""

    for ($i = 1; $i -le $Runs; $i++) {
        Write-Host "--- Run $i/$Runs (v2) ---" -ForegroundColor Yellow
        $runArgs = $baseArgs + @("--v2")
        Write-Host "Command: $binary $($runArgs -join ' ')"

        # Start power logging
        $powerLogFile = $null
        $powerProcess = $null
        if ($script:HasPowerGadget) {
            $powerLogFile = Join-Path $powerLogDir "v2_run_$i.csv"
            $powerProcess = Start-PowerLog -LogFile $powerLogFile
            Start-Sleep -Milliseconds 500  # Let IPG start
        }

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

        # Stop power logging
        Stop-PowerLog -Process $powerProcess
        Start-Sleep -Milliseconds 200  # Let IPG finish writing

        # Get power stats
        $powerStats = @{ AvgPower = 0; MaxPower = 0; Energy = 0 }
        if ($script:HasPowerGadget -and $powerLogFile) {
            $powerStats = Get-PowerStats -LogFile $powerLogFile
        }

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
                $v2Powers += $powerStats.AvgPower

                $powerInfo = if ($script:HasPowerGadget -and $powerStats.AvgPower -gt 0) {
                    " | Power: $(Format-Power $powerStats.AvgPower)"
                } else { "" }

                Write-Host ">>> Result: OK (Hashrate: $hashrate H/s$powerInfo)" -ForegroundColor Green
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

        # Start power logging
        $powerLogFile = $null
        $powerProcess = $null
        if ($script:HasPowerGadget) {
            $powerLogFile = Join-Path $powerLogDir "v1_run_$i.csv"
            $powerProcess = Start-PowerLog -LogFile $powerLogFile
            Start-Sleep -Milliseconds 500  # Let IPG start
        }

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

        # Stop power logging
        Stop-PowerLog -Process $powerProcess
        Start-Sleep -Milliseconds 200  # Let IPG finish writing

        # Get power stats
        $powerStats = @{ AvgPower = 0; MaxPower = 0; Energy = 0 }
        if ($script:HasPowerGadget -and $powerLogFile) {
            $powerStats = Get-PowerStats -LogFile $powerLogFile
        }

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
                $v1Powers += $powerStats.AvgPower

                $powerInfo = if ($script:HasPowerGadget -and $powerStats.AvgPower -gt 0) {
                    " | Power: $(Format-Power $powerStats.AvgPower)"
                } else { "" }

                Write-Host ">>> Result: OK (Hashrate: $hashrate H/s$powerInfo)" -ForegroundColor Green
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
                    -V2Powers $v2Powers -V1Powers $v1Powers `
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
        [double[]]$V2Powers,
        [double[]]$V1Powers,
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

    # Power stats
    $v2PowerStats = Get-Stats $V2Powers
    $v1PowerStats = Get-Stats $V1Powers

    # Efficiency (hashes per Joule)
    $v1Efficiency = if ($v1PowerStats.Avg -gt 0 -and $v1Stats.Avg -gt 0) {
        [math]::Round($v1Stats.Avg / $v1PowerStats.Avg, 2)
    } else { "N/A" }
    $v2Efficiency = if ($v2PowerStats.Avg -gt 0 -and $v2Stats.Avg -gt 0) {
        [math]::Round($v2Stats.Avg / $v2PowerStats.Avg, 2)
    } else { "N/A" }

    # Power note
    if ($script:HasPowerGadget -and $v1PowerStats.Avg -gt 0) {
        $powerNote = "Power measured via Intel Power Gadget"
    } else {
        $powerNote = "Power measurement: Not available (non-Intel CPU or IPG not installed)"
    }

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
  Avg Power:     $(Format-Power $v2PowerStats.Avg)
  Max Power:     $(Format-Power $v2PowerStats.Max)
  Efficiency:    ${v2Efficiency} H/J

V1 (without --v2 flag):
  Crashes:       $V1Crashes / $Runs
  Success:       $V1Success / $Runs
  Avg Hashrate:  $($v1Stats.Avg) H/s
  Relative:      ${v1RelSpeed}%
  VM+AES/s:      $v1VmaesFmt
  Avg Power:     $(Format-Power $v1PowerStats.Avg)
  Max Power:     $(Format-Power $v1PowerStats.Max)
  Efficiency:    ${v1Efficiency} H/J

======================================
"@

    Write-Host $output

    # --- GitHub markdown summary ---
    $powerSection = if ($script:HasPowerGadget -and $v1PowerStats.Avg -gt 0) {
        @"

| Algorithm | Hashrate | Relative Speed | VM+AES/s | Power | Efficiency |
|-----------|----------|----------------|----------|-------|------------|
| RandomX v1 | $($v1Stats.Avg) | ${v1RelSpeed}% | $v1VmaesFmt | $(Format-Power $v1PowerStats.Avg) | ${v1Efficiency} H/J |
| RandomX v2 | $($v2Stats.Avg) | ${v2RelSpeed}% | $v2VmaesFmt | $(Format-Power $v2PowerStats.Avg) | ${v2Efficiency} H/J |
"@
    } else {
        @"

| Algorithm | Hashrate | Relative Speed | VM+AES/s |
|-----------|----------|----------------|----------|
| RandomX v1 | $($v1Stats.Avg) | ${v1RelSpeed}% | $v1VmaesFmt |
| RandomX v2 | $($v2Stats.Avg) | ${v2RelSpeed}% | $v2VmaesFmt |
"@
    }

    $detailedStats = if ($script:HasPowerGadget -and $v1PowerStats.Avg -gt 0) {
        @"

| Metric | V1 | V2 |
|--------|----|----|
| Successful runs | $($v1Stats.Count) | $($v2Stats.Count) |
| Hashrate (avg) | $($v1Stats.Avg) H/s | $($v2Stats.Avg) H/s |
| Hashrate (std dev) | $($v1Stats.StdDev) H/s | $($v2Stats.StdDev) H/s |
| Hashrate (min) | $($v1Stats.Min) H/s | $($v2Stats.Min) H/s |
| Hashrate (max) | $($v1Stats.Max) H/s | $($v2Stats.Max) H/s |
| Power (avg) | $(Format-Power $v1PowerStats.Avg) | $(Format-Power $v2PowerStats.Avg) |
| Power (max) | $(Format-Power $v1PowerStats.Max) | $(Format-Power $v2PowerStats.Max) |
| Efficiency | ${v1Efficiency} H/J | ${v2Efficiency} H/J |
"@
    } else {
        @"

| Metric | V1 | V2 |
|--------|----|----|
| Successful runs | $($v1Stats.Count) | $($v2Stats.Count) |
| Hashrate (avg) | $($v1Stats.Avg) H/s | $($v2Stats.Avg) H/s |
| Hashrate (std dev) | $($v1Stats.StdDev) H/s | $($v2Stats.StdDev) H/s |
| Hashrate (min) | $($v1Stats.Min) H/s | $($v2Stats.Min) H/s |
| Hashrate (max) | $($v1Stats.Max) H/s | $($v2Stats.Max) H/s |
"@
    }

    $ghSummary = @"

======================================
GITHUB COPY-PASTE SUMMARY (Markdown)
======================================

### RandomX v2 Benchmark Results

**$($script:CpuModel)**
$powerSection

**Config:** threads=$($script:OptimalThreads), affinity=$($script:AffinityMask), init=$($script:InitThreads)

**Stability:** V1 crashes: $V1Crashes/$Runs, V2 crashes: $V2Crashes/$Runs

---

<details>
<summary>Detailed Statistics</summary>

$detailedStats
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

    if ($script:HasPowerGadget) {
        $fullOutput += "`n`nRaw V2 Power (Watts):`n"
        $fullOutput += ($V2Powers -join "`n")
        $fullOutput += "`n`nRaw V1 Power (Watts):`n"
        $fullOutput += ($V1Powers -join "`n")
    }

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
    Install-IntelPowerGadget
    Install-MSRTool

    # Check for updates and build if needed
    if (-not (Update-RandomX)) {
        Build-RandomX
    }

    Get-OptimalSettings
    Apply-MSROptimizations
    Run-Benchmarks

    Write-Host ""
    Write-Banner "Benchmark complete!"
}

Main
