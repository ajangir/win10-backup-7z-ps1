<#
.SYNOPSIS
    Automated Windows 10 Full/Differential Backup Script with App Export and Exclusions.
.DESCRIPTION
    1. Exports installed applications via Winget.
    2. Reads target paths and exclusion rules from backup-config.json.
    3. Filters files dynamically based on modification date (Differential vs Full).
    4. Compresses selected items into a .7z archive using 7-Zip.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

# --- 0. Environment & Paths Setup ---
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ConfigPath = Join-Path $ScriptDir "backup-config.json"

if (-not (Test-Path $ConfigPath)) {
    Write-Error "Configuration file not found at: $ConfigPath"
    exit 1
}

$Config = Get-Content $ConfigPath | ConvertFrom-Json
$DestDir = [System.IO.Path]::GetFullPath($Config.DestinationDirectory)
if (-not (Test-Path $DestDir)) {
    New-Item -ItemType Directory -Force -Path $DestDir | Out-Null
}

$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$LogFile = Join-Path $DestDir "backup_$Timestamp.log"

function Write-Log {
    param([string]$Message)
    $LogEntry = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Write-Host $LogEntry
    Add-Content -Path $LogFile -Value $LogEntry
}

Write-Log "=== Starting Windows Backup Job ==="

# --- 1. Export Installed Applications (Winget) ---
Write-Log "Step 1: Exporting installed applications list via winget..."
$AppsExportPath = Join-Path $DestDir "installed_apps_$Timestamp.json"
try {
    winget export -o $AppsExportPath --accept-source-agreements --accept-package-agreements | Out-Null
    Write-Log "Successfully exported app list to: $AppsExportPath"
} catch {
    Write-Log "Warning: Winget export failed or winget is unavailable: $_"
}

# --- 2. Locate 7-Zip Executable ---
$SevenZPaths = @(
    "$env:ProgramFiles\7-Zip\7z.exe",
    "${env:ProgramFiles(x86)}\7-Zip\7z.exe",
    "$env:LOCALAPPDATA\Programs\7-Zip\7z.exe"
)
$SevenZExe = $SevenZPaths | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $SevenZExe) {
    Write-Error "7-Zip executable (7z.exe) not found. Please install 7-Zip."
    exit 1
}
Write-Log "Using 7-Zip binary: $SevenZExe"

# --- 3. Determine Backup Type & Reference Timestamp ---
$FullBackupMarker = Join-Path $DestDir "last_full_backup.timestamp"
$IsDifferential = $false
$ReferenceTime = $null

if ((Test-Path $FullBackupMarker) -and ($Config.BackupType -eq "Differential")) {
    $IsDifferential = $true
    $ReferenceTime = (Get-Item $FullBackupMarker).LastWriteTime
    Write-Log "Mode: DIFFERENTIAL backup (Changes since reference time: $ReferenceTime)"
} else {
    Write-Log "Mode: FULL backup (Creating new baseline reference)"
    New-Item -ItemType File -Force -Path $FullBackupMarker | Out-Null
    $ReferenceTime = (Get-Item $FullBackupMarker).LastWriteTime
}

# --- 4. Gather & Filter Files based on JSON Exclusions ---
Write-Log "Step 2 & 3: Scanning source paths and applying exclusion filters..."

$IncludedFiles = [System.Collections.Generic.List[string]]::new()
$Exclusions = $Config.Exclusions

foreach ($SourcePath in $Config.Sources) {
    if (-not (Test-Path $SourcePath)) {
        Write-Log "Warning: Source path does not exist, skipping: $SourcePath"
        continue
    }

    Write-Log "Scanning source: $SourcePath"
    $Files = Get-ChildItem -Path $SourcePath -Recurse -File -Force -ErrorAction SilentlyContinue

    foreach ($File in $Files) {
        $FilePath = $File.FullName
        $ShouldExclude = $false

        # Check against exclusion list (substring or directory name match)
        foreach ($Excl in $Exclusions) {
            if ($FilePath -like "*\$Excl\*" -or $FilePath -like "*\$Excl" -or $File.Name -eq $Excl) {
                $ShouldExclude = $true
                break
            }
        }

        # Skip dot folders (e.g., .cache, .npm) if not explicitly caught
        if (-not $ShouldExclude -and ($FilePath -match '\\\.[^\\]+')) {
            # Check if any parent segment starts with a dot
            $Segments = $FilePath.Split([System.IO.Path]::DirectorySeparatorChar)
            foreach ($Seg in $Segments) {
                if ($Seg.StartsWith(".") -and $Exclusions -contains $Seg) {
                    $ShouldExclude = $true
                    break
                }
            }
        }

        if ($ShouldExclude) { continue }

        # Differential filter: Only include if modified after the last full backup marker
        if ($IsDifferential -and ($File.LastWriteTime -le $ReferenceTime)) {
            continue
        }

        $IncludedFiles.Add($FilePath)
    }
}

Write-Log "Total files queued for backup: $($IncludedFiles.Count)"

if ($IncludedFiles.Count -eq 0) {
    Write-Log "No changes detected. Backup complete."
    exit 0
}

# --- 5. Write File List to Temporary Manifest for 7-Zip ---
$TempListFile = [System.IO.Path]::GetTempFileName()
$IncludedFiles | Out-File -FilePath $TempListFile -Encoding utf8

# --- 6. Execute 7-Zip Compression ---
$ArchiveName = if ($IsDifferential) { "backup_diff_$Timestamp.7z" } else { "backup_full_$Timestamp.7z" }
$ArchivePath = Join-Path $DestDir $ArchiveName
$CompressionLevel = $Config.CompressionLevel

Write-Log "Step 4 & 5: Compressing archive to destination disk: $ArchivePath"

# 7-Zip switches:
# a = add to archive
# -t7z = 7z format
# -mx = compression level (0-9)
# -r- = recurse off (since we already provided absolute paths via listfile)
# @ = read filenames from listfile
$ArgList = @(
    "a",
    "`"$ArchivePath`"",
    "@`"$TempListFile`"",
    "-t7z",
    "-mx$CompressionLevel",
    "-r-"
)

$ProcessInfo = Start-Process -FilePath $SevenZExe -ArgumentList $ArgList -NoNewWindow -PassThru -Wait

# Clean up temp file
Remove-Item $TempListFile -Force -ErrorAction SilentlyContinue

if ($ProcessInfo.ExitCode -eq 0) {
    Write-Log "SUCCESS: Backup archive created successfully at $ArchivePath"
} else {
    Write-Log "ERROR: 7-Zip exited with error code $($ProcessInfo.ExitCode)"
    exit $ProcessInfo.ExitCode
}

Write-Log "=== Backup Job Complete ==="