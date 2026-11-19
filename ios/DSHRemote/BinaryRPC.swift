import Foundation

enum BinaryRPC {
    // Binary Remote fields are exposed to the JSON stores as base64 strings.
    static func decode(_ data: Data, contentType: String?) throws -> Data {
        guard let contentType, contentType.lowercased().hasPrefix("multipart/form-data") else { return data }
        guard let boundaryField = contentType.components(separatedBy: ";").dropFirst().first(where: { $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("boundary=") }) else { throw APIError.invalidResponse }
        let boundary = boundaryField.trimmingCharacters(in: .whitespaces).dropFirst("boundary=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        guard !boundary.isEmpty, boundary.count <= 200 else { throw APIError.invalidResponse }
        let delimiter = Data(("\r\n--" + boundary).utf8)
        let opening = Data(("--" + boundary + "\r\n").utf8)
        guard data.starts(with: opening) else { throw APIError.invalidResponse }
        var cursor = opening.count
        var parts: [String: Data] = [:]
        while true {
            guard let headersEnd = data.range(of: Data("\r\n\r\n".utf8), in: cursor..<data.endIndex),
                  let headers = String(data: data[cursor..<headersEnd.lowerBound], encoding: .utf8),
                  let disposition = headers.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("content-disposition:") }),
                  let nameRange = disposition.range(of: "(?:^|;\\s*)name=\"([^\"]+)\"", options: .regularExpression),
                  let nameStart = disposition[nameRange].range(of: "name=\"") else { throw APIError.invalidResponse }
            let name = String(disposition[nameStart.upperBound..<nameRange.upperBound].dropLast())
            guard parts[name] == nil, let end = data.range(of: delimiter, in: headersEnd.upperBound..<data.endIndex) else { throw APIError.invalidResponse }
            parts[name] = Data(data[headersEnd.upperBound..<end.lowerBound])
            cursor = end.upperBound
            if data[cursor...].starts(with: Data("--".utf8)) { break }
            guard data[cursor...].starts(with: Data("\r\n".utf8)) else { throw APIError.invalidResponse }
            cursor += 2
        }
        guard let metadata = parts.removeValue(forKey: "metadata") else { throw APIError.invalidResponse }
        guard var envelope = try? JSONDecoder().decode(JSON.self, from: metadata) else { throw APIError.invalidResponse }
        guard envelope["result"]["ok"].boolean, !envelope["attachments"].array.isEmpty else { throw APIError.invalidResponse }
        for attachment in envelope["attachments"].array {
            guard attachment["codec"] == "bytes", let part = attachment["part"].string, let bytes = parts.removeValue(forKey: part) else { throw APIError.invalidResponse }
            envelope["result"]["value"] = try replacing(envelope["result"]["value"], path: attachment["path"].array[...], bytes: bytes)
        }
        guard parts.isEmpty else { throw APIError.invalidResponse }
        return try JSONEncoder().encode(envelope)
    }
    private static func replacing(_ value: JSON, path: ArraySlice<JSON>, bytes: Data) throws -> JSON {
        guard let head = path.first else {
            guard value == .null else { throw APIError.invalidResponse }
            return .string(bytes.base64EncodedString())
        }
        switch value {
        case .object(var fields):
            guard let key = head.string, let child = fields[key] else { throw APIError.invalidResponse }
            fields[key] = try replacing(child, path: path.dropFirst(), bytes: bytes)
            return .object(fields)
        case .array(var items):
            guard let index = head.int, items.indices.contains(index) else { throw APIError.invalidResponse }
            items[index] = try replacing(items[index], path: path.dropFirst(), bytes: bytes)
            return .array(items)
        default: throw APIError.invalidResponse
        }
    }
}
