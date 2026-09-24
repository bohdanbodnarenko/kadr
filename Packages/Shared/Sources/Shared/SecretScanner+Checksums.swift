import Foundation

/// The checksums that turn "looks like a card or an IBAN" into "is one".
public extension SecretScanner {
    /// Luhn (mod-10) as used on payment cards. Double every second digit from the right;
    /// a valid number sums to a multiple of 10.
    static func luhnIsValid(_ digits: String) -> Bool {
        guard digits.allSatisfy(\.isNumber), digits.count >= 13 else { return false }
        var sum = 0
        var doubleIt = false
        for character in digits.reversed() {
            guard let value = character.wholeNumberValue else { return false }
            var term = value
            if doubleIt {
                term *= 2
                if term > 9 {
                    term -= 9
                }
            }
            sum += term
            doubleIt.toggle()
        }
        return sum % 10 == 0
    }

    /// ISO 13616: move the first four characters to the end, A=10…Z=35, remainder 1 mod 97.
    static func ibanChecksumIsValid(_ compact: String) -> Bool {
        let compact = compact.uppercased()
        guard compact.count >= 15, compact.count <= 34 else { return false }
        let letters = CharacterSet.letters
        let alphanumerics = CharacterSet.alphanumerics
        guard compact.unicodeScalars.allSatisfy({ alphanumerics.contains($0) }) else { return false }
        guard compact.prefix(2).unicodeScalars.allSatisfy({ letters.contains($0) }) else { return false }

        let rearranged = String(compact.dropFirst(4) + compact.prefix(4))
        var remainder = 0
        for character in rearranged {
            if let digit = character.wholeNumberValue {
                remainder = (remainder * 10 + digit) % 97
            } else if let ascii = character.asciiValue, character.isASCII, character.isLetter {
                let value = Int(ascii - 65) + 10
                remainder = (remainder * 100 + value) % 97
            } else {
                return false
            }
        }
        return remainder == 1
    }
}
