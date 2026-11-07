@echo off
setlocal
cd /d "%~dp0"
start "Blueberry server" /min cmd /c "node server.mjs"
timeout /t 1 /nobreak >nul
start "Blueberry" "http://localhost:4173/index.html"
