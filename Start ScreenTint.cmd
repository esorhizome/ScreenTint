@echo off
rem Launches ScreenTint without leaving a console window open.
rem This file does exactly one thing: run ScreenTint.ps1 from this folder.
start "" /min powershell.exe -NoProfile -Sta -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0ScreenTint.ps1"
