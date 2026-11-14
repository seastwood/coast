// Sets a custom Finder icon on a file, folder, or mounted volume.
// Usage: set_icon <icon.icns> <target_path>
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let img = NSImage(contentsOfFile: args[1]) else {
    print("usage: set_icon <icon.icns> <target_path>")
    exit(1)
}
let ok = NSWorkspace.shared.setIcon(img, forFile: args[2], options: [])
print("setIcon(\(args[2])) -> \(ok)")
exit(ok ? 0 : 1)
