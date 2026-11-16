# win10-backup-7z-ps1
 backup using 7z and config

App Recovery (winget): Automatically generates an immutable .json app inventory file before zipping, allowing you to restore apps via winget import -i installed_apps.json.

Exclusion Engine: Uses regular expressions and path substring matching to strip out bloat like node_modules, AppData\Local\Temp, package caches, and .git objects.

Differential Intelligence: If BackupType is set to Differential, it evaluates file LastWriteTime against the recorded LastFullBackup timestamp, zipping only delta changes.

Memory-Safe File List Handling: Feeds files to 7-Zip via an external @filelist.txt pointer to avoid command-line argument length limits when backing up thousands of user files.

Fixing the Exclusion Match Error (Unrecognized escape sequence \L): PowerShell’s -match operator treats backslashes (\) as regex escape characters, causing AppData\Local or \.cache\ to throw syntax errors. Replacing -match with the native .IndexOf() string method eliminates backslash and regex parsing errors entirely.

Logging Winget Package Warnings: Capturing the output stream of winget export using 2>&1 allows scanning for "not available from any source" warnings and recording them directly into your backup log file.
