#!/bin/bash
# Install claude-notify into ~/.claude/hooks/claude-notify/
# Run from the repo root: bash install.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="$USERPROFILE/.claude/hooks/claude-notify"

echo "Installing claude-notify to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

# Copy scripts
cp "$SCRIPT_DIR/notify.ps1"   "$INSTALL_DIR/"
cp "$SCRIPT_DIR/popup.ps1"    "$INSTALL_DIR/"
cp "$SCRIPT_DIR/attention.cmd" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/resume.cmd"   "$INSTALL_DIR/"
cp "$SCRIPT_DIR/setup.sh"     "$INSTALL_DIR/"
cp "$SCRIPT_DIR/SaveHwnd.cs"  "$INSTALL_DIR/"
cp "$SCRIPT_DIR/codex-hook.ps1" "$INSTALL_DIR/"

# Compile save-hwnd.exe
CSC="/c/Windows/Microsoft.NET/Framework64/v4.0.30319/csc.exe"
WPF_DIR="C:\\Windows\\Microsoft.NET\\Framework64\\v4.0.30319\\WPF"

if [ -f "$CSC" ]; then
    echo "Compiling save-hwnd.exe..."
    "$CSC" -nologo -optimize+ \
        -out:"$INSTALL_DIR/save-hwnd.exe" \
        "$INSTALL_DIR/SaveHwnd.cs" \
        -r:"$WPF_DIR\\UIAutomationClient.dll" \
        -r:"$WPF_DIR\\UIAutomationTypes.dll" \
        -r:System.Management.dll
    echo "Compiled successfully."
else
    echo "WARNING: .NET Framework csc.exe not found at $CSC"
    echo "Falling back to bundled save-hwnd.exe (if present in repo)."
    if [ -f "$SCRIPT_DIR/save-hwnd.exe" ]; then
        cp "$SCRIPT_DIR/save-hwnd.exe" "$INSTALL_DIR/"
    else
        echo "ERROR: No save-hwnd.exe available. Compile manually or install .NET Framework 4."
        exit 1
    fi
fi

chmod +x "$INSTALL_DIR/setup.sh"

# Register hooks in Claude Code settings
SETTINGS_FILE="$USERPROFILE/.claude/settings.json"

if [ ! -f "$SETTINGS_FILE" ]; then
    echo "WARNING: $SETTINGS_FILE not found."
    echo "Create it manually or run Claude Code once first."
    echo ""
    echo "Required hooks config (add to settings.json):"
    echo '  "hooks": {'
    echo '    "Stop": [{"matcher": "", "hooks": [{"type": "command", "command": "C:\\Users\\'"$USERNAME"'\\.claude\\hooks\\claude-notify\\attention.cmd", "timeout": 10}]}],'
    echo '    "UserPromptSubmit": [{"matcher": "", "hooks": [{"type": "command", "command": "C:\\Users\\'"$USERNAME"'\\.claude\\hooks\\claude-notify\\resume.cmd", "timeout": 10}]}]'
    echo '  }'
else
    echo ""
    echo "Settings file exists at $SETTINGS_FILE"
    echo "Ensure it has the following hooks registered:"
    echo ""
    echo '  "hooks": {'
    echo '    "Stop": [{"matcher": "", "hooks": [{"type": "command", "command": "...\\attention.cmd", "timeout": 10}]}],'
    echo '    "UserPromptSubmit": [{"matcher": "", "hooks": [{"type": "command", "command": "...\\resume.cmd", "timeout": 10}]}]'
    echo '  }'
fi

echo ""
echo "Installation complete."
echo ""
echo "NEXT STEPS:"
echo "  1. Open each Claude Code tab in Windows Terminal"
echo "  2. Make sure you are FOCUSED on that tab's WT window"
echo "  3. Run: bash ~/.claude/hooks/claude-notify/setup.sh"
echo "  4. Repeat for every Claude Code tab"
echo ""
echo "Re-run setup.sh after: WT restart, tab reorder, adding/removing tabs."
