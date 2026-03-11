@echo off
chcp 65001 >nul 2>&1
set PYTHONIOENCODING=utf-8
title ZeroChat Server
echo ========================================
echo   ZeroChat Server
echo   启动中...
echo ========================================
echo.

cd /d "%~dp0"

REM 检查 Python
python --version >nul 2>&1
if errorlevel 1 (
    echo [错误] 未找到 Python，请先安装 Python 3.11+
    pause
    exit /b 1
)

REM 检查依赖
if not exist "venv" (
    echo [信息] 首次运行，正在创建虚拟环境...
    python -m venv venv
    call venv\Scripts\activate.bat
    pip install -r requirements.txt
) else (
    call venv\Scripts\activate.bat
)

echo.
echo [信息] 启动服务器...
echo.
python main.py

pause
