@echo off
chcp 65001 >nul
title JACK 弱电调试宝
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0server.ps1"
