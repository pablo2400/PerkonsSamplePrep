import AppKit

let appPath = "/Users/pawel/PerkonsSamplePrep/PerkonsSamplePrep.app"
let imagePath = "/Users/pawel/Downloads/Perkons_1_2.png"

guard let image = NSImage(contentsOfFile: imagePath) else {
    fatalError("Cannot read icon image")
}

let ok = NSWorkspace.shared.setIcon(image, forFile: appPath, options: [])
if !ok {
    fatalError("Could not set app icon")
}
