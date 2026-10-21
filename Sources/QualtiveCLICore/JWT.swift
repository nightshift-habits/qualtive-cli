import Foundation

/// Reads (does not verify) JWT claims, for display only. The API verifies tokens.
public enum JWT {
    public static func claims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let data = Base64URL.decode(String(parts[1])) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func userDescription(_ claims: [String: Any]) -> String? {
        for key in ["user", "userID", "userId", "sub"] {
            if let value = claims[key] {
                return stringValue(value)
            }
        }
        return nil
    }

    static func stringValue(_ value: Any) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        case let dictionary as [String: Any]:
            for key in ["email", "name", "id"] {
                if let nested = dictionary[key].flatMap(stringValue) { return nested }
            }
            return nil
        default:
            return nil
        }
    }
}

public enum Base64URL {
    public static func encode<D: DataProtocol>(_ data: D) -> String {
        Data(data).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}
