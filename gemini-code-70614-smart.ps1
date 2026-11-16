<#
.SYNOPSIS
    Smart Differential Backup Script for Windows 10
.DESCRIPTION
    Exports installed applications via winget, reads include/exclude rules from JSON,
    filters files for differential backups, and packages them using 7-Zip to a secondary drive.
#>

[CmdletBinding()]
param(
    [string]$ConfigPath = ".\backup-config-smart.json"
)

# Load Configuration
if (-not (Test-Path $ConfigPath)) {
    Write-Error "Configuration file not found at $ConfigPath"
    exit 1
}

$Config = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json

# Validate 7-Zip
if (-not (Test-Path $Config.SevenZipPath)) {
    Write-Error "7-Zip executable not found at $($Config.SevenZipPath). Please check your config."
    exit 1
}

# Ensure destination directory exists
if (-not (Test-Path $Config.DestinationPath)) {
    New-Item -ItemType Directory -Force -Path $Config.DestinationPath | Out-Null
}

$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$BackupName = "Backup_$($Config.BackupType.ToLower())_$Timestamp"
$TempStagingDir = Join-Path $env:TEMP $BackupName
New-Item -ItemType Directory -Force -Path $TempStagingDir | Out-Null

Write-Host "[*] Step 0: Exporting installed applications list via winget..." -ForegroundColor Cyan
$WingetExportPath = Join-Path $Config.DestinationPath "installed_apps_$Timestamp.json"
try {
    winget export -o $WingetExportPath --accept-source-agreements --include-versions
    Write-Host "[+] Winget apps exported successfully to $WingetExportPath" -ForegroundColor Green
} catch {
    Write-Warning "[-] Winget export failed or winget is unavailable: $_"
}

Write-Host "[*] Step 1 & 2: Parsing folders and applying exclusion filters..." -ForegroundColor Cyan

# Determine cut-off time for differential backups
$CutoffTime = $null
if ($Config.BackupType -eq "Differential" -and $Config.LastFullBackup) {
    $CutoffTime = [DateTime]$Config.LastFullBackup
    Write-Host "[+] Differential mode active. Backing up files modified since: $CutoffTime" -ForegroundColor Yellow
} else {
    Write-Host "[+] Full backup mode active." -ForegroundColor Green
    $Config.BackupType = "Full"
}

$FilesToBackup = [System.Collections.Generic.List[string]]::new()

foreach ($BaseDir in $Config.IncludeFolders) {
    if (-not (Test-Path $BaseDir)) {
        Write-Warning "[-] Source path not found, skipping: $BaseDir"
        continue
    }

    Write-Host "    Scanning: $BaseDir"
    $AllFiles = Get-ChildItem -Path $BaseDir -Recurse -File -Force -ErrorAction SilentlyContinue

    foreach ($File in $AllFiles) {
        $FilePath = $File.FullName
        $RelPath = $FilePath.Substring($BaseDir.Length)

        # Check exclusion patterns
        $Excluded = $false
        foreach ($Pattern in $Config.ExcludePatterns) {
            if ($FilePath -match [regex]::Escape($Pattern) -or $RelPath -match $Pattern) {
                $Excluded = $true
                break
            }
        }

        if ($Excluded) { continue }

        # Check differential timestamp condition
        if ($CutoffTime -and $File.LastWriteTime -le $CutoffTime) {
            continue
        }

        $FilesToBackup.Add($FilePath)
    }
}

Write-Host "[+] Found $($FilesToBackup.Count) files to back up." -ForegroundColor Green

if ($FilesToBackup.Count -eq 0) {
    Write-Host "[-] No new or modified files found to backup." -ForegroundColor Yellow
    Remove-Item -Recurse -Force $TempStagingDir
    exit 0
}

# Create a temporary list file for 7-Zip to process large file sets safely
$FileListPath = Join-Path $TempStagingDir "filelist.txt"
$FilesToBackup | Out-File -FilePath $FileListPath -Encoding utf8

Write-Host "[*] Step 4 & 5: Compressing files into .7z archive on destination drive..." -ForegroundColor Cyan
$ArchiveName = "$BackupName.7z"
$DestinationArchive = Join-Path $Config.DestinationPath $ArchiveName

$CompressionArg = "-mx=$($Config.CompressionLevel)"
$SevenZipArgs = @(
    "a",
    "-t7z",
    $CompressionArg,
    "-m0=LZMA2",
    $DestinationArchive,
    "@" + $FileListPath
)

& $Config.SevenZipPath $SevenZipArgs

if ($LASTEXITCODE -eq 0) {
    Write-Host "[+] Backup completed successfully!" -ForegroundColor Green
    Write-Host "[+] Archive saved to: $DestinationArchive" -ForegroundColor Cyan

    # If this was a full backup, update the config timestamp for future differential runs
    if ($Config.BackupType -eq "Full") {
        $Config.LastFullBackup = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        $Config | ConvertTo-Json -Depth 4 | Set-Content $ConfigPath
        Write-Host "[+] Updated config with new Full Backup timestamp." -ForegroundColor Yellow
    }
} else {
    Write-Error "[-] 7-Zip encountered an error during compression. Exit code: $LASTEXITCODE"
}

# Cleanup staging files
Remove-Item -Recurse -Force $TempStagingDir