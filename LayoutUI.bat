@echo off
:: Open the Dev Layout Composer (Python + customtkinter).
:: Prefer the py launcher: a venv earlier on PATH (e.g. hermes) can shadow the real python.
set "PY=python"
where py >nul 2>&1 && set "PY=py -3"
%PY% -c "import customtkinter" >nul 2>&1
if errorlevel 1 (
    echo Installing dependencies...
    %PY% -m pip install -r "%~dp0requirements.txt"
)
%PY% "%~dp0layout_ui.py" %*
