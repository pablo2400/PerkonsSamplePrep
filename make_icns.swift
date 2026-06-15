import Foundation

let iconset = URL(fileURLWithPath: "/Users/pawel/PerkonsSamplePrep/AppIcon.iconset")
let output = URL(fileURLWithPath: "/Users/pawel/PerkonsSamplePrep/PerkonsSamplePrep.app/Contents/Resources/AppIcon.icns")
let chunks: [(String, String)] = [
    ("icp4", "icon_16x16.png"),
    ("icp5", "icon_32x32.png"),
    ("icp6", "icon_32x32@2x.png"),
    ("ic07", "icon_128x128.png"),
    ("ic08", "icon_256x256.png"),
    ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png"),
]

func be32(_ value: UInt32) -> [UInt8] {
    [
        UInt8((value >> 24) & 0xff),
        UInt8((value >> 16) & 0xff),
        UInt8((value >> 8) & 0xff),
        UInt8(value & 0xff),
    ]
}

var body = Data()
for (type, filename) in chunks {
    let bytes = try Data(contentsOf: iconset.appendingPathComponent(filename))
    body.append(contentsOf: type.utf8)
    body.append(contentsOf: be32(UInt32(bytes.count + 8)))
    body.append(bytes)
}

var data = Data()
data.append(contentsOf: "icns".utf8)
data.append(contentsOf: be32(UInt32(body.count + 8)))
data.append(body)
try data.write(to: output)
