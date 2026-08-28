import Foundation

/// Turns what a user typed into something FTS5 will accept (docs/03 §5 P3).
///
/// FTS5's `MATCH` takes a query language, not a phrase: bare punctuation is a syntax
/// error, `AND`/`OR`/`NEAR` are operators, and an unbalanced quote fails the statement.
/// A search field must never do that — someone typing `stripe "error` mid-thought should
/// get results, not an exception. So every token is quoted (which makes it a literal) and
/// given a prefix `*` (so results appear while they are still typing).
public enum HistorySearchQuery {
    /// The FTS5 expression for `text`, or nil when there is nothing to search for.
    public static func expression(for text: String) -> String? {
        let tokens = tokens(in: text)
        guard !tokens.isEmpty else { return nil }
        // Quoted, so operators are literals; `*` outside the quotes, which is where FTS5
        // wants the prefix marker.
        return tokens
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }
            .joined(separator: " ")
    }

    /// The words in a search string.
    ///
    /// Split on anything that is not alphanumeric so `stripe.com/errors` becomes three
    /// searchable tokens — which is how someone looks for a screenshot of a URL.
    static func tokens(in text: String) -> [String] {
        text
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !$0.isEmpty }
    }
}
