import Foundation

enum CountryFlag {
    static func emoji(alpha2: String) -> String? {
        let code = alpha2.uppercased()
        guard code.count == 2 else { return nil }
        let base: UInt32 = 0x1F1E6
        var scalars = String.UnicodeScalarView()
        for letter in code.unicodeScalars {
            guard (0x41...0x5A).contains(letter.value) else { return nil }
            guard let scalar = Unicode.Scalar(base + (letter.value - 0x41)) else { return nil }
            scalars.append(scalar)
        }
        return String(scalars)
    }
}
