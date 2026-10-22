import Foundation

public enum AirPrintJob {
    public static func arguments(queue: String, file: String, environment: [String: String]) throws -> [String] {
        guard PrinterCare.validQueue(queue), file.hasPrefix("/"), !file.contains("\0") else { throw ConfigurationError.invalidReply }
        let format = environment["CONTENT_TYPE"] ?? ""
        guard ["application/pdf", "image/jpeg", "image/urf", "image/pwg-raster"].contains(format) else {
            throw ComponentFiles.failure("This AirPrint document format is not supported by the bridge.")
        }
        let copiesText = environment["IPP_COPIES"] ?? "1"
        guard copiesText.allSatisfy({ $0.isASCII && $0.isNumber }), let copies = Int(copiesText), (1...99).contains(copies) else {
            throw ComponentFiles.failure("The AirPrint copy count is outside the supported range.")
        }
        var arguments = ["-d", queue, "-t", "AirPrint document", "-n", String(copies), "-o", "document-format=" + format]
        if let collection = environment["IPP_MEDIA_COL"] {
            guard validMediaCollection(collection) else { throw ConfigurationError.invalidReply }
            arguments += ["-o", "media-col=" + collection]
        } else if let media = environment["IPP_MEDIA"] {
            guard media.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$"#, options: .regularExpression) != nil else { throw ConfigurationError.invalidReply }
            arguments += ["-o", "media=" + media]
        }
        if environment["IPP_PRINT_COLOR_MODE"] == "monochrome" {
            // Verified 1500W PPD: EPIJ_Ink_ 0/On means grayscale.
            arguments += ["-o", "EPIJ_Ink_=0", "-o", "ColorModel=Mono"]
        }
        arguments.append(file)
        return arguments
    }
    public static func validMediaCollection(_ text: String) -> Bool {
        guard text.utf8.count <= 4096, text.first == "{", text.last == "}",
              text.range(of: #"^[A-Za-z0-9_.,={} -]+$"#, options: .regularExpression) != nil else { return false }
        var depth = 0
        for (index, character) in text.enumerated() {
            if character == "{" { depth += 1 }
            if character == "}" { depth -= 1 }
            if depth < 0 || (depth == 0 && index != text.count - 1) { return false }
        }
        return depth == 0
    }
}
