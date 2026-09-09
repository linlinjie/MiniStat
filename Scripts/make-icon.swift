import Foundation

struct IconRepresentation {
    let type: String
    let fileName: String
}

let representations = [
    IconRepresentation(type: "icp4", fileName: "icon_16x16.png"),
    IconRepresentation(type: "icp5", fileName: "icon_32x32.png"),
    IconRepresentation(type: "icp6", fileName: "icon_32x32@2x.png"),
    IconRepresentation(type: "ic07", fileName: "icon_128x128.png"),
    IconRepresentation(type: "ic08", fileName: "icon_128x128@2x.png"),
    IconRepresentation(type: "ic09", fileName: "icon_256x256@2x.png"),
    IconRepresentation(type: "ic10", fileName: "icon_512x512@2x.png")
]

func bigEndianBytes(_ value: UInt32) -> [UInt8] {
    let converted = value.bigEndian
    return withUnsafeBytes(of: converted) { Array($0) }
}

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("Usage: make-icon <iconset> <output.icns>\n".utf8))
    exit(64)
}

let iconsetURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
var chunks = Data()

for representation in representations {
    let pngURL = iconsetURL.appendingPathComponent(representation.fileName)
    let png = try Data(contentsOf: pngURL)
    guard let type = representation.type.data(using: .ascii), type.count == 4 else {
        throw CocoaError(.fileReadCorruptFile)
    }

    chunks.append(type)
    chunks.append(contentsOf: bigEndianBytes(UInt32(png.count + 8)))
    chunks.append(png)
}

var icns = Data("icns".utf8)
icns.append(contentsOf: bigEndianBytes(UInt32(chunks.count + 8)))
icns.append(chunks)
try icns.write(to: outputURL, options: .atomic)
