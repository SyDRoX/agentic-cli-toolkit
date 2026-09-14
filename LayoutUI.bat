@echo off
:: Open the Dev Layout Composer (Python + customtkinter).
python -c "import customtkinter" >nul 2>&1
if errorlevel 1 (
    echo Installing dependencies...
    python -m pip install -r "%~dp0requirements.txt"
)
python "%~dp0layout_ui.py" %*
