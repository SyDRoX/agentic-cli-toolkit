# PyInstaller spec for the Dev Layout Composer (onefile, windowed).
#
# Build with Build-LayoutUI.ps1, which sets --distpath to the repo root so LayoutUI.exe
# lands beside custom-layouts/, repos.json and ps1-scripts/ -- none of which are bundled.
# The app resolves those from the exe's own folder (see _root_dir in layout_ui.py).

from PyInstaller.utils.hooks import collect_all

# customtkinter loads its widget-scaling JSON and bundled fonts from package data at import
# time, so a bare module graph is not enough.
ctk_datas, ctk_binaries, ctk_hiddenimports = collect_all("customtkinter")

a = Analysis(
    ["layout_ui.py"],
    pathex=[],
    binaries=ctk_binaries,
    datas=ctk_datas,
    hiddenimports=ctk_hiddenimports,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=["numpy", "pandas", "matplotlib", "PIL.ImageQt", "pytest"],
    noarchive=False,
)

pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.datas,
    [],
    name="LayoutUI",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    runtime_tmpdir=None,
    console=False,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)
