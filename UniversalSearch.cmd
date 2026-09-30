@echo off
rem Universal Search System - double-click to start (UniversalSearch.ps1 must be in the same folder)
if exist "%SystemRoot%\System32\conhost.exe" (
  start "" /min "%SystemRoot%\System32\conhost.exe" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0UniversalSearch.ps1"
) else (
  start "" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0UniversalSearch.ps1"
)
