@echo off
setlocal
chcp 65001 >nul 2>&1
set "PYTHONIOENCODING=utf-8"
set "PYTHONUTF8=1"
REM 避免外部 Python/Pip 路径把依赖装到项目环境之外。
set "PYTHONHOME="
set "PYTHONPATH="
set "PYTHONUSERBASE="
set "PYTHONNOUSERSITE=1"
set "PIP_TARGET="
set "PIP_PREFIX="
set "PIP_USER="
set "PIP_CONFIG_FILE=nul"
title ZeroChat Server
echo ========================================
echo   ZeroChat Server
echo   启动中...
echo ========================================
echo [信息] Python 需由用户手动安装；本脚本只安装项目依赖。
echo.

cd /d "%~dp0" || exit /b 1
if not exist "requirements.txt" goto incomplete_package
if not exist "tools\check_environment.py" goto incomplete_package
if not exist "main.py" goto incomplete_package
set "VENV_PYTHON=%~dp0venv\Scripts\python.exe"
set "NEEDS_INSTALL="

REM 不依赖 activate.bat；移动过的环境可能仍写着旧路径。
if not exist "%VENV_PYTHON%" (
    if /i "%~1"=="--check" goto failed
    call :create_venv
    if errorlevel 1 goto failed
    set "NEEDS_INSTALL=1"
)

set "VIRTUAL_ENV=%~dp0venv"
set "PATH=%~dp0venv\Scripts;%PATH%"
"%VENV_PYTHON%" -I -X utf8 tools\check_environment.py --runtime-only
if errorlevel 1 (
    echo [错误] 项目虚拟环境检查失败。不要复制其他电脑的 venv；请在可写目录重新解压干净发布包。
    goto failed
)
if defined NEEDS_INSTALL goto install_dependencies
"%VENV_PYTHON%" -I -X utf8 tools\check_environment.py
if errorlevel 1 goto install_dependencies
goto ready

:install_dependencies
if /i "%~1"=="--check" goto failed
echo [信息] 依赖缺失或版本不符，仅安装到 "%~dp0venv"。
"%VENV_PYTHON%" -I -X utf8 -m pip --require-virtualenv install -r "%~dp0requirements.txt"
if errorlevel 1 (
    echo [错误] 依赖安装失败，未启动服务；请检查网络后重试。
    echo [信息] 请使用 Windows x64 和 Python 3.11 x64，并确认安装目录可写。
    goto failed
)
"%VENV_PYTHON%" -I -X utf8 tools\check_environment.py
if errorlevel 1 goto failed

:ready
if /i "%~1"=="--check" exit /b 0
"%VENV_PYTHON%" -I -X utf8 tools\check_environment.py --imports-only
if errorlevel 1 goto failed
if /i "%~1"=="--prepare" exit /b 0
echo.
echo [信息] 启动服务器...
echo.
"%VENV_PYTHON%" -E -s -X utf8 "%~dp0main.py"
if errorlevel 1 goto failed
pause
exit /b 0

:failed
if /i "%~1"=="--check" exit /b 1
if /i "%~1"=="--prepare" exit /b 1
pause
exit /b 1

:incomplete_package
echo [错误] 后端文件不完整，请重新解压完整发布包。
goto failed

:create_venv
echo [信息] 首次运行，依赖仅安装到 "%~dp0venv"。
if defined ZEROCHAT_PYTHON goto explicit_python
REM 优先选择项目验证版本，不依赖 PATH 中默认的 Python 版本。
py -3.11 -I -X utf8 tools\check_environment.py --base-only >nul 2>&1
if not errorlevel 1 (
    py -3.11 -I -X utf8 -m venv "%~dp0venv"
    exit /b
)
python -I -X utf8 tools\check_environment.py --base-only >nul 2>&1
if not errorlevel 1 (
    python -I -X utf8 -m venv "%~dp0venv"
    exit /b
)
echo [错误] 未找到 Python 3.11 x64。请手动安装并勾选添加到 PATH 后，再双击 start.bat。
echo [信息] 本脚本不会下载或安装 Python；已安装时可用 ZEROCHAT_PYTHON 指定 python.exe 完整路径。
exit /b 1

:explicit_python
"%ZEROCHAT_PYTHON%" -I -X utf8 tools\check_environment.py --base-only
if errorlevel 1 exit /b 1
"%ZEROCHAT_PYTHON%" -I -X utf8 -m venv "%~dp0venv"
exit /b
