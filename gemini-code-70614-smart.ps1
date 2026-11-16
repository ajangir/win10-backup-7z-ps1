<#
.SYNOPSIS
    Automated Windows 10 Full/Differential Backup Script with App Export, Streamlined Logging, and Safe Exclusions.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

# --- 0. Environment & Paths Setup ---
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ConfigPath = Join-Path $ScriptDir "backup-config-smart.json"

if (-not (Test-Path $ConfigPath)) {
    Write-Error "Configuration file not found at: $ConfigPath"
    exit 1
}

$Config = Get-Content $ConfigPath | ConvertFrom-Json
$DestDir = [System.IO.Path]::GetFullPath($Config.DestinationPath)
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

# --- 1. Export Installed Applications (Winget & Log Warnings) ---
Write-Log "Step 1: Exporting installed applications list via winget..."
$AppsExportPath = Join-Path $DestDir "installed_apps_$Timestamp.json"
try {
    # Capture output and error streams to catch missing source warnings
    $WingetOutput = & winget export -o $AppsExportPath --accept-source-agreements --accept-package-agreements 2>&1
    
    foreach ($Line in $WingetOutput) {
        $LineStr = $Line.ToString()
        if ($LineStr -match "not available from any source") {
            Write-Log "Winget Warning: $LineStr"
        }
    }
    Write-Log "Successfully exported app list to: $AppsExportPath"
} catch {
    Write-Log "Warning: Winget export encountered issues: $_"
}

$OutputFile = Join-Path $config.DestinationPath "installed_program_folders.txt"
$Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

# Define target directories (handles environment variables safely)
$ProgramDirs = @(
    $env:ProgramFiles,
    ${env:ProgramFiles(x86)}
)

$Inventory = foreach ($BaseDir in $ProgramDirs) {
    if (Test-Path $BaseDir) {
        Get-ChildItem -Path $BaseDir -Directory | ForEach-Object {
            # Format each entry with timestamp, folder name, and full path
            "$Timestamp | $($_.Name) | $($_.FullName)"
        }
    }
}

# Write results to file and output to console
$Inventory | Out-File -FilePath $OutputFile -Encoding utf8
Write-Host "Programs Names of folder saved to: $OutputFile" -ForegroundColor Green

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

# --- Safe Timestamp for Filenames (No Colons!) ---
$FileTimestamp = Get-Date -Format "yyyyMMdd_HHmmss"

# --- 6. Execute 7-Zip Directly on Defined Sources Only ---
$ArchiveName = if ($IsDifferential) { "backup_diff_$FileTimestamp.7z" } else { "backup_full_$FileTimestamp.7z" }
$ArchivePath = Join-Path $DestDir $ArchiveName
$CompressionLevel = $Config.CompressionLevel

Write-Log "Step 4 & 5: Compressing targeted sources to: $ArchivePath"

# Build argument array cleanly. Do NOT add manual escaped quotes (`"`), 
# as Start-Process automatically wraps arguments containing spaces.
$ArgList = [System.Collections.Generic.List[string]]::new()
$ArgList.Add("a")
$ArgList.Add($ArchivePath)
$ArgList.Add("-t7z")
$ArgList.Add("-mx$CompressionLevel")
$ArgList.Add("-r0")

# Add valid source paths
foreach ($SourcePath in $Config.Sources) {
    if (Test-Path $SourcePath) {
        Write-Log "Including source in archive: $SourcePath"
        $ArgList.Add($SourcePath)
    } else {
        Write-Log "Warning: Configured source path does not exist, skipping: $SourcePath"
    }
}

# Add exclusion rules using 7-Zip exclusion syntax (-xr!)
foreach ($Excl in $Config.Exclusions) {
    $ArgList.Add("-xr!$Excl")
}

# Execute 7-Zip process safely
$ProcessInfo = Start-Process -FilePath $SevenZExe -ArgumentList $ArgList -NoNewWindow -PassThru -Wait

if ($ProcessInfo.ExitCode -eq 0) {
    Write-Log "SUCCESS: Backup archive created successfully at $ArchivePath"
} else {
    Write-Log "ERROR: 7-Zip exited with error code $($ProcessInfo.ExitCode)"
    exit $ProcessInfo.ExitCode
}

Write-Log "=== Backup Job Complete ==="