#!/bin/bash
# Run this from within a Claude Code terminal to configure notifications.
# It captures the current WT window and selected tab for this session.
#
# Usage:
#   bash ~/.claude/hooks/claude-notify/setup.sh                        # auto-detect
#   bash ~/.claude/hooks/claude-notify/setup.sh 3                      # override tab index
#   bash ~/.claude/hooks/claude-notify/setup.sh 3 "Repos / Claude 1"  # override tab index + label

TAB_OVERRIDE="$1"
LABEL="$2"
HWND_OVERRIDE="$3"

if [ -z "$WT_SESSION" ]; then
    echo "ERROR: WT_SESSION not set. Run this from Windows Terminal."
    exit 1
fi

DIR="$USERPROFILE/.claude/hooks/claude-notify"

if [ -n "$HWND_OVERRIDE" ]; then
    # Use provided HWND (from DevLayout or other automated launcher)
    printf '%s' "$HWND_OVERRIDE" > "$DIR/.hwnd-$WT_SESSION"
    HWND="$HWND_OVERRIDE"
else
    # Capture current foreground window + selected tab index
    "$DIR/save-hwnd.exe"

    # Save window handle
    if [ -f "$DIR/.hwnd" ]; then
        cp "$DIR/.hwnd" "$DIR/.hwnd-$WT_SESSION"
        HWND=$(cat "$DIR/.hwnd")
    else
        echo "ERROR: Failed to capture window handle."
        exit 1
    fi
fi

# Save tab index (use override if provided, otherwise use detected value)
if [ -n "$TAB_OVERRIDE" ]; then
    printf '%s' "$TAB_OVERRIDE" > "$DIR/.tabindex-$WT_SESSION"
    TAB="$TAB_OVERRIDE"
elif [ -f "$DIR/.tabindex" ]; then
    cp "$DIR/.tabindex" "$DIR/.tabindex-$WT_SESSION"
    TAB=$(cat "$DIR/.tabindex")
else
    echo "ERROR: Failed to capture tab index."
    exit 1
fi

# Save label if provided
if [ -n "$LABEL" ]; then
    printf '%s' "$LABEL" > "$DIR/.label-$WT_SESSION"
fi

echo "Configured for session $WT_SESSION"
echo "  Window: $HWND"
echo "  Tab index: $TAB"
[ -n "$LABEL" ] && echo "  Label: $LABEL"
echo ""
echo "Notifications will target this window and tab."
echo "Re-run this command if you rearrange tabs or restart WT."
