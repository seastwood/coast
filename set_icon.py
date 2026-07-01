"""Set a custom Finder icon on a file, folder, or mounted volume.

Usage: set_icon.py <icon.icns> <target_path>
"""
import sys
from AppKit import NSImage, NSWorkspace

icns, target = sys.argv[1], sys.argv[2]
img = NSImage.alloc().initWithContentsOfFile_(icns)
if img is None:
    print(f"could not load icon: {icns}")
    sys.exit(1)
ok = NSWorkspace.sharedWorkspace().setIcon_forFile_options_(img, target, 0)
print(f"setIcon({target}) -> {bool(ok)}")
sys.exit(0 if ok else 1)
