import Foundation

/// Normalizes user search queries, generates forgiving fallback queries when strict matching
/// returns no results, and reranks search hits by multi-word token relevance.
struct SearchQueryPlan: Equatable, Sendable {
    let rawQuery: String
    let primaryQuery: String
    let positiveWords: [String]
    let preservedTokens: [String]
    let scoringTokens: [String]

    private static let filterPrefixes: Set<String> = [
        "ext", "type", "kind", "in", "size", "mtime", "modified",
        "re", "path", "limit", "grep", "content", "regex", "sym", "symbol", "git",
    ]

    private static let wordSeparators = CharacterSet(
        charactersIn: "-_,;:()[]{}+=&@#~`|<>\"'\\/"
    )

    init(_ query: String) {
        self.rawQuery = query
        let rawTokens = Self.tokenizeRespectingQuotes(query)
        var preserved: [String] = []
        var positives: [String] = []
        var positiveSeen = Set<String>()

        for token in rawTokens {
            if Self.shouldPreserveVerbatim(token) {
                preserved.append(token)
                for word in Self.extractScoringWords(fromPreservedToken: token) {
                    let lower = word.lowercased()
                    if !lower.isEmpty, positiveSeen.insert(lower).inserted {
                        positives.append(word)
                    }
                }
            } else {
                for word in Self.sanitizePlainToken(token) {
                    let lower = word.lowercased()
                    if !lower.isEmpty, positiveSeen.insert(lower).inserted {
                        positives.append(word)
                    }
                }
            }
        }

        // Rebuild the primary query with preserved filter/modifier tokens and sanitized words.
        var primaryParts: [String] = []
        var rebuildSeen = Set<String>()
        for token in rawTokens {
            if Self.shouldPreserveVerbatim(token) {
                primaryParts.append(token)
            } else {
                for word in Self.sanitizePlainToken(token) {
                    let lower = word.lowercased()
                    if !lower.isEmpty, rebuildSeen.insert(lower).inserted {
                        primaryParts.append(word)
                    }
                }
            }
        }

        let builtPrimary = primaryParts.joined(separator: " ")
        self.primaryQuery =
            builtPrimary.isEmpty
            ? query.trimmingCharacters(in: .whitespacesAndNewlines)
            : builtPrimary
        self.positiveWords = positives
        self.preservedTokens = preserved

        var scoring: [String] = []
        var scoringSeen = Set<String>()
        for word in positives {
            for sub in Self.splitIdentifierWords(word) {
                if !sub.isEmpty, scoringSeen.insert(sub).inserted {
                    scoring.append(sub)
                }
            }
        }
        self.scoringTokens = scoring
    }

    /// Generates tiered fallback query groups to try when `primaryQuery` returns 0 hits.
    /// Queries within a tier are merged; once a tier produces hits, later tiers are skipped.
    func fallbackTiers() -> [[String]] {
        var tiers: [[String]] = []
        var seen: Set<String> = [
            rawQuery.lowercased(),
            primaryQuery.lowercased(),
        ]

        func makeCandidate(_ words: [String]) -> String? {
            guard !words.isEmpty else { return nil }
            let candidate = (preservedTokens + words).joined(separator: " ")
            let key = candidate.lowercased()
            guard !candidate.isEmpty, seen.insert(key).inserted else { return nil }
            return candidate
        }

        // Tier 1: If any positive word contains dots or camelCase transitions (e.g. "fidoDiscovery"
        // or "report.2025"), splitting it into separate words allows out-of-order and
        // non-adjacent word matching in fsearch.
        if !scoringTokens.isEmpty {
            let expanded = scoringTokens.joined(separator: " ")
            let currentPositives = positiveWords.map { $0.lowercased() }.joined(separator: " ")
            if expanded != currentPositives, let candidate = makeCandidate(scoringTokens) {
                tiers.append([candidate])
            }
        }

        let baseWords = !scoringTokens.isEmpty ? scoringTokens : positiveWords

        // Tier 2: Multi-word partial fallback (drop 1 word at a time).
        // When a user types 2+ words and one word is absent or has a short-word typo,
        // querying the remaining word(s) surfaces candidates that SearchRelevance then
        // scores across all original tokens (including Damerau-Levenshtein typo matching).
        if baseWords.count >= 2 {
            var dropOneTier: [String] = []
            for dropIndex in baseWords.indices.reversed() {
                var subset = baseWords
                subset.remove(at: dropIndex)
                if let candidate = makeCandidate(subset) {
                    dropOneTier.append(candidate)
                }
                if dropOneTier.count >= 4 { break }
            }
            if !dropOneTier.isEmpty {
                tiers.append(dropOneTier)
            }
        }

        // Tier 3: fsearch disables typo tolerance for tokens shorter than 5 characters.
        // Generate adjacent-character transposition variants for 3-4 letter alphabetic words
        // (e.g., "mian" -> "main", "fiod" -> "fido").
        var transpositionTier: [String] = []
        for (index, word) in baseWords.enumerated()
        where (3...4).contains(word.count) && word.allSatisfy(\.isLetter) {
            for swapped in Self.adjacentTranspositions(of: word).prefix(2) {
                var mutated = baseWords
                mutated[index] = swapped
                if let candidate = makeCandidate(mutated) {
                    transpositionTier.append(candidate)
                }
            }
        }
        if !transpositionTier.isEmpty {
            tiers.append(transpositionTier)
        }

        // Tier 4: For 3+ word queries where 2-word combinations still matched nothing,
        // fall back to individual words.
        if baseWords.count >= 3 {
            var singleWordTier: [String] = []
            for word in baseWords where word.count >= 2 {
                if let candidate = makeCandidate([word]) {
                    singleWordTier.append(candidate)
                }
                if singleWordTier.count >= 4 { break }
            }
            if !singleWordTier.isEmpty {
                tiers.append(singleWordTier)
            }
        }

        return tiers
    }

    /// Flattened list of fallback queries across all tiers.
    func fallbackQueries(maxCount: Int = 6) -> [String] {
        Array(fallbackTiers().joined().prefix(maxCount))
    }

    // MARK: - Tokenization & Sanitization Helpers

    private static func tokenizeRespectingQuotes(_ query: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false

        for ch in query {
            if ch == "\"" {
                inQuotes.toggle()
                current.append(ch)
            } else if ch.isWhitespace && !inQuotes {
                if !current.isEmpty {
                    tokens.append(current)
                    current.removeAll(keepingCapacity: true)
                }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private static func shouldPreserveVerbatim(_ token: String) -> Bool {
        guard !token.isEmpty else { return false }
        if token.hasPrefix("\"") || token.hasSuffix("\"") { return true }
        if token.hasPrefix("!") && token.count > 1 { return true }
        if token.hasPrefix("'") && token.count > 1 { return true }
        if token.hasPrefix("^") && token.count > 1 { return true }
        if token.hasSuffix("$") && token.count > 1 { return true }
        if token.contains("*") || token.contains("?") { return true }

        if let colonIndex = token.firstIndex(of: ":") {
            let prefix = String(token[..<colonIndex]).lowercased()
            let rest = token[token.index(after: colonIndex)...]
            if filterPrefixes.contains(prefix), !rest.isEmpty {
                return true
            }
        }

        // Preserve intentional path queries like "src/main" or "docs/report".
        if token.contains("/") {
            let parts = token.split(separator: "/", omittingEmptySubsequences: false)
            if parts.count >= 2, parts.allSatisfy({ !$0.isEmpty }) {
                return true
            }
        }

        return false
    }

    private static func extractScoringWords(fromPreservedToken token: String) -> [String] {
        if token.hasPrefix("!") { return [] }
        if let colonIndex = token.firstIndex(of: ":") {
            let prefix = String(token[..<colonIndex]).lowercased()
            if filterPrefixes.contains(prefix) {
                return []
            }
        }
        var stripped = token
        if stripped.hasPrefix("\"") && stripped.hasSuffix("\"") && stripped.count >= 2 {
            stripped.removeFirst()
            stripped.removeLast()
        } else {
            if stripped.hasPrefix("'") || stripped.hasPrefix("^") {
                stripped.removeFirst()
            }
            if stripped.hasSuffix("$") {
                stripped.removeLast()
            }
        }
        return sanitizePlainToken(stripped)
    }

    private static func sanitizePlainToken(_ token: String) -> [String] {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Preserve hidden-file dot tokens like ".zshrc" or ".gitignore" when they have no separators.
        if trimmed.hasPrefix("."), trimmed.count > 1 {
            let tail = String(trimmed.dropFirst())
            if tail.rangeOfCharacter(from: wordSeparators) == nil,
                !tail.contains(".")
            {
                return [trimmed]
            }
        }

        let parts = trimmed.components(separatedBy: wordSeparators)
        var words: [String] = []
        for rawPart in parts {
            let cleaned = rawPart.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if !cleaned.isEmpty {
                words.append(cleaned)
            }
        }
        return words
    }

    /// Splits a filename, path component, or identifier into normalized lowercase words
    /// across punctuation, `_`, `-`, `.`, camelCase, and letter-digit boundaries.
    static func splitIdentifierWords(_ text: String) -> [String] {
        let scalars = Array(text.unicodeScalars)
        guard !scalars.isEmpty else { return [] }

        var words: [String] = []
        var current: [UnicodeScalar] = []

        func flush() {
            if !current.isEmpty {
                let word = String(String.UnicodeScalarView(current)).lowercased()
                if !word.isEmpty {
                    words.append(word)
                }
                current.removeAll(keepingCapacity: true)
            }
        }

        for i in scalars.indices {
            let scalar = scalars[i]
            let isAlpha = CharacterSet.letters.contains(scalar)
            let isDigit = CharacterSet.decimalDigits.contains(scalar)

            guard isAlpha || isDigit else {
                flush()
                continue
            }

            if !current.isEmpty {
                let prev = scalars[i - 1]
                let prevIsUpper = CharacterSet.uppercaseLetters.contains(prev)
                let prevIsLower = CharacterSet.lowercaseLetters.contains(prev)
                let prevIsDigit = CharacterSet.decimalDigits.contains(prev)
                let currIsUpper = CharacterSet.uppercaseLetters.contains(scalar)
                let currIsDigit = isDigit

                let nextIsLower: Bool = {
                    guard i + 1 < scalars.count else { return false }
                    return CharacterSet.lowercaseLetters.contains(scalars[i + 1])
                }()

                // Split on camelCase ("fidoDiscovery" -> "fido", "discovery"),
                // acronym-to-word ("HTMLParser" -> "html", "parser"),
                // or letter/digit boundary ("v2" -> "v", "2").
                if (prevIsLower && currIsUpper)
                    || (prevIsUpper && currIsUpper && nextIsLower)
                    || (prevIsDigit != currIsDigit)
                {
                    flush()
                }
            }
            current.append(scalar)
        }
        flush()
        return words
    }

    static func adjacentTranspositions(of word: String) -> [String] {
        let chars = Array(word.lowercased())
        guard chars.count >= 3 else { return [] }
        var variants: [String] = []
        // Prefer swapping interior characters first, then boundary characters.
        let indices = Array(1..<(chars.count - 1)) + [0]
        var seen: Set<String> = [word.lowercased()]
        for i in indices where i + 1 < chars.count {
            guard chars[i] != chars[i + 1] else { continue }
            var copy = chars
            copy.swapAt(i, i + 1)
            let candidate = String(copy)
            if seen.insert(candidate).inserted {
                variants.append(candidate)
            }
        }
        return variants
    }
}

/// Evaluates and reranks search hits so multi-word queries, non-adjacent words, out-of-order
/// words, and word-boundary matches rank above scattered single-character subsequence matches.
enum SearchRelevance {
    enum TokenMatchTier: Int, Comparable {
        case unmatched = 0
        case subsequence = 1
        case typoWord = 2
        case substringOrPathWord = 3
        case prefixFilenameWord = 4
        case exactFilenameWord = 5

        static func < (lhs: TokenMatchTier, rhs: TokenMatchTier) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    struct Evaluation: Equatable {
        let strongTokenCount: Int
        let matchedTokenCount: Int
        let filenameWordMatches: Int
        let compositeScore: Int64
    }

    static func rank(hits: [Hit], for plan: SearchQueryPlan) -> [Hit] {
        guard hits.count > 1, !plan.scoringTokens.isEmpty else { return hits }
        let evaluated = hits.map { hit in
            (hit: hit, eval: evaluate(hit: hit, plan: plan))
        }
        return evaluated.sorted { lhs, rhs in
            if lhs.eval.strongTokenCount != rhs.eval.strongTokenCount {
                return lhs.eval.strongTokenCount > rhs.eval.strongTokenCount
            }
            if lhs.eval.matchedTokenCount != rhs.eval.matchedTokenCount {
                return lhs.eval.matchedTokenCount > rhs.eval.matchedTokenCount
            }
            if lhs.eval.compositeScore != rhs.eval.compositeScore {
                return lhs.eval.compositeScore > rhs.eval.compositeScore
            }
            if lhs.hit.score != rhs.hit.score {
                return lhs.hit.score > rhs.hit.score
            }
            if lhs.hit.name.count != rhs.hit.name.count {
                return lhs.hit.name.count < rhs.hit.name.count
            }
            return lhs.hit.path < rhs.hit.path
        }.map(\.hit)
    }

    static func evaluate(hit: Hit, plan: SearchQueryPlan) -> Evaluation {
        let tokens = plan.scoringTokens
        guard !tokens.isEmpty else {
            return Evaluation(
                strongTokenCount: 0, matchedTokenCount: 0, filenameWordMatches: 0,
                compositeScore: hit.score)
        }

        let nameLower = hit.name.lowercased()
        let stemLower = ((hit.name as NSString).deletingPathExtension).lowercased()
        let parentLower = hit.parent.lowercased()

        let stemWords = SearchQueryPlan.splitIdentifierWords(stemLower)
        let extWords = SearchQueryPlan.splitIdentifierWords(
            (hit.name as NSString).pathExtension.lowercased())
        let nameWords = stemWords + extWords
        let pathWords = SearchQueryPlan.splitIdentifierWords(parentLower)

        var usedNameWordIndices = Set<Int>()
        var matchedNamePositions: [Int] = []
        var strongCount = 0
        var matchedCount = 0
        var filenameWordCount = 0
        var bonus: Int64 = 0

        for token in tokens {
            let match = matchToken(
                token,
                nameLower: nameLower,
                stemWordCount: stemWords.count,
                nameWords: nameWords,
                pathWords: pathWords,
                parentLower: parentLower,
                usedNameWordIndices: &usedNameWordIndices
            )

            switch match.tier {
            case .exactFilenameWord:
                strongCount += 1
                matchedCount += 1
                filenameWordCount += 1
                bonus += 600
                if match.wordIndex == 0 {
                    bonus += 150
                }
                if let idx = match.wordIndex, idx < stemWords.count {
                    bonus += 100
                }
                if let idx = match.wordIndex {
                    matchedNamePositions.append(idx)
                }

            case .prefixFilenameWord:
                strongCount += 1
                matchedCount += 1
                filenameWordCount += 1
                bonus += 420 + match.extraBonus
                if match.wordIndex == 0 {
                    bonus += 90
                }
                if let idx = match.wordIndex {
                    matchedNamePositions.append(idx)
                }

            case .substringOrPathWord:
                strongCount += 1
                matchedCount += 1
                if match.inFilename {
                    filenameWordCount += 1
                }
                bonus += match.extraBonus

            case .typoWord:
                strongCount += 1
                matchedCount += 1
                filenameWordCount += 1
                bonus += 180
                if let idx = match.wordIndex {
                    matchedNamePositions.append(idx)
                }

            case .subsequence:
                matchedCount += 1
                bonus -= 300

            case .unmatched:
                bonus -= 500
            }
        }

        // Exact stem coverage bonus when the query words match every word in the filename stem.
        if !stemWords.isEmpty, filenameWordCount >= stemWords.count,
            usedNameWordIndices.filter({ $0 < stemWords.count }).count == stemWords.count
        {
            bonus += 350
        }

        // Multi-word filename synergy: reward candidates where multiple query words match real
        // words/prefixes in the filename, regardless of whether they are adjacent or in order.
        if tokens.count >= 2 && filenameWordCount >= 2 {
            bonus += Int64(filenameWordCount - 1) * 400
        }

        // Word coverage ratio bonus: prefer concise filenames where the query words represent
        // a larger fraction of the filename's words.
        if !nameWords.isEmpty && filenameWordCount > 0 {
            let ratio = min(Double(filenameWordCount) / Double(nameWords.count), 1.0)
            bonus += Int64(ratio * 200.0)
        }

        // Gentle tie-breaker for preserving word order and adjacency when two files both
        // contain all the query words.
        if matchedNamePositions.count >= 2 {
            var inOrderPairs = 0
            var adjacentPairs = 0
            for i in 0..<(matchedNamePositions.count - 1) {
                let first = matchedNamePositions[i]
                let second = matchedNamePositions[i + 1]
                if second > first {
                    inOrderPairs += 1
                    if second == first + 1 {
                        adjacentPairs += 1
                    }
                }
            }
            if inOrderPairs == matchedNamePositions.count - 1 {
                bonus += 60
            }
            bonus += Int64(adjacentPairs) * 40
        }

        return Evaluation(
            strongTokenCount: strongCount,
            matchedTokenCount: matchedCount,
            filenameWordMatches: filenameWordCount,
            compositeScore: hit.score + bonus
        )
    }

    private struct TokenMatchResult {
        let tier: TokenMatchTier
        let wordIndex: Int?
        let inFilename: Bool
        let extraBonus: Int64
    }

    private static func matchToken(
        _ token: String,
        nameLower: String,
        stemWordCount: Int,
        nameWords: [String],
        pathWords: [String],
        parentLower: String,
        usedNameWordIndices: inout Set<Int>
    ) -> TokenMatchResult {
        // 1. Exact whole-word match in filename (prefer unused word index, then any word index).
        if let idx = nameWords.indices.first(where: {
            !usedNameWordIndices.contains($0) && nameWords[$0] == token
        }) ?? nameWords.firstIndex(of: token) {
            usedNameWordIndices.insert(idx)
            return TokenMatchResult(
                tier: .exactFilenameWord, wordIndex: idx, inFilename: true, extraBonus: 0)
        }

        // 2. Prefix of a whole word in filename (prefer unused word index).
        if let idx = nameWords.indices.first(where: {
            !usedNameWordIndices.contains($0) && nameWords[$0].hasPrefix(token)
        }) ?? nameWords.indices.first(where: { nameWords[$0].hasPrefix(token) }) {
            usedNameWordIndices.insert(idx)
            let coverage = Int64(
                (Double(token.count) / Double(max(nameWords[idx].count, 1))) * 80.0)
            return TokenMatchResult(
                tier: .prefixFilenameWord, wordIndex: idx, inFilename: true, extraBonus: coverage)
        }

        // 3. Compound match across adjacent filename words (e.g., "fidodevice" -> "fido" + "device").
        if nameWords.count >= 2 && token.count >= 4 {
            for start in nameWords.indices {
                var combined = ""
                for end in start..<min(start + 3, nameWords.count) {
                    combined += nameWords[end]
                    if combined == token
                        || (combined.hasPrefix(token) && token.count > nameWords[start].count)
                    {
                        for k in start...end { usedNameWordIndices.insert(k) }
                        return TokenMatchResult(
                            tier: .prefixFilenameWord, wordIndex: start, inFilename: true,
                            extraBonus: 60)
                    }
                }
            }
        }

        // 4. Contiguous substring in filename, or exact/prefix word in parent directory path.
        if nameLower.contains(token) {
            return TokenMatchResult(
                tier: .substringOrPathWord, wordIndex: nil, inFilename: true, extraBonus: 260)
        }
        if pathWords.contains(token) {
            return TokenMatchResult(
                tier: .substringOrPathWord, wordIndex: nil, inFilename: false, extraBonus: 240)
        }
        if pathWords.contains(where: { $0.hasPrefix(token) }) {
            return TokenMatchResult(
                tier: .substringOrPathWord, wordIndex: nil, inFilename: false, extraBonus: 160)
        }

        // 5. Typo match (Damerau-Levenshtein distance <= 1) against a filename word.
        if token.count >= 3 {
            for idx in nameWords.indices {
                let candidate = nameWords[idx]
                if isWithinOneEditOrSwap(token, candidate)
                    || (candidate.count > token.count
                        && isWithinOneEditOrSwap(token, String(candidate.prefix(token.count))))
                {
                    usedNameWordIndices.insert(idx)
                    return TokenMatchResult(
                        tier: .typoWord, wordIndex: idx, inFilename: true, extraBonus: 0)
                }
            }
        }

        // 6. Subsequence match in filename or path.
        if isSubsequence(token, of: nameLower) || isSubsequence(token, of: parentLower) {
            return TokenMatchResult(
                tier: .subsequence, wordIndex: nil, inFilename: false, extraBonus: 0)
        }

        return TokenMatchResult(
            tier: .unmatched, wordIndex: nil, inFilename: false, extraBonus: 0)
    }

    static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        guard !needle.isEmpty else { return true }
        var needleIter = needle.makeIterator()
        guard var current = needleIter.next() else { return true }
        for ch in haystack {
            if ch == current {
                if let next = needleIter.next() {
                    current = next
                } else {
                    return true
                }
            }
        }
        return false
    }

    /// Returns true if `lhs` and `rhs` have Damerau-Levenshtein distance <= 1
    /// (at most one insertion, deletion, substitution, or adjacent transposition).
    static func isWithinOneEditOrSwap(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        let n = a.count
        let m = b.count
        if abs(n - m) > 1 { return false }

        var i = 0
        while i < n && i < m && a[i] == b[i] {
            i += 1
        }
        if i == n && i == m { return true }

        if n == m {
            // Single substitution: rest after i+1 matches
            if a[(i + 1)...] == b[(i + 1)...] {
                return true
            }
            // Adjacent transposition: a[i] == b[i+1] && a[i+1] == b[i]
            if i + 1 < n, a[i] == b[i + 1], a[i + 1] == b[i], a[(i + 2)...] == b[(i + 2)...] {
                return true
            }
            return false
        } else if n + 1 == m {
            // Single insertion in b
            return a[i...] == b[(i + 1)...]
        } else {
            // Single deletion from a
            return a[(i + 1)...] == b[i...]
        }
    }
}

/// Searches the currently viewed local folder tree when the background fsearch daemon
/// has not indexed a consent-gated or external folder (such as iCloud Drive under
/// `~/Library/Mobile Documents`, `~/Desktop`, `~/Documents`, `~/Downloads`, or `/Volumes`)
/// or when the global index returns no hits.
enum LocalFolderSearch {
    private static let gatedHomeSubpaths: [String] = [
        "Desktop",
        "Documents",
        "Downloads",
        "Library/Mobile Documents",
        "Library/CloudStorage",
        "Library/Containers",
        "Library/Group Containers",
        "Pictures/Photos Library.photoslibrary",
    ]

    static func isSkippedWithoutFullDiskAccess(_ path: String, home: String = NSHomeDirectory())
        -> Bool
    {
        if path == "/Volumes" || path.hasPrefix("/Volumes/") {
            return true
        }
        for sub in gatedHomeSubpaths {
            let full = home + "/" + sub
            if path == full || path.hasPrefix(full + "/") {
                return true
            }
        }
        return false
    }

    static func search(
        root: URL,
        seedHits: [Hit],
        plan: SearchQueryPlan,
        hidden: Bool,
        fileType: String,
        recursive: Bool = true,
        maxVisitedEntries: Int = 12_000,
        maxDepth: Int = 5
    ) throws -> [Hit] {
        guard !plan.scoringTokens.isEmpty else { return [] }
        var candidates: [Hit] = []
        var visitedPaths = Set<String>()
        var visitedCount = 0

        for hit in seedHits {
            try Task.checkCancellation()
            if !hidden && hit.name.hasPrefix(".") {
                continue
            }
            if visitedPaths.insert(hit.path).inserted {
                candidates.append(hit)
                visitedCount += 1
            }
        }

        // BFS traversal of the current folder and its subdirectories using fast bulk listing.
        var queue: [(url: URL, depth: Int)] = recursive ? [(root, 0)] : []
        var queueIndex = 0

        while queueIndex < queue.count && visitedCount < maxVisitedEntries {
            try Task.checkCancellation()
            let (dirURL, depth) = queue[queueIndex]
            queueIndex += 1

            guard let children = try? LocalFiles.list(dirURL, hidden: true) else {
                continue
            }
            for child in children {
                try Task.checkCancellation()
                if !hidden && child.name.hasPrefix(".") {
                    continue
                }
                if visitedPaths.insert(child.path).inserted {
                    candidates.append(child)
                    visitedCount += 1
                }
                if depth + 1 < maxDepth, child.kind == "dir", child.isFolder {
                    queue.append((child.url, depth + 1))
                }
                if visitedCount >= maxVisitedEntries {
                    break
                }
            }
        }

        var fullMatches: [Hit] = []
        var partialMatches: [Hit] = []
        let requiredTokens = plan.scoringTokens.count

        for hit in candidates {
            try Task.checkCancellation()
            guard passesFilters(hit: hit, plan: plan, fileType: fileType) else {
                continue
            }
            let eval = SearchRelevance.evaluate(hit: hit, plan: plan)
            if eval.strongTokenCount >= requiredTokens {
                let synthesized = Hit(
                    path: hit.path,
                    kind: hit.kind,
                    size: hit.size,
                    mtime: hit.mtime,
                    score: max(hit.score, 1500)
                )
                fullMatches.append(synthesized)
            } else if requiredTokens >= 2 && eval.strongTokenCount >= requiredTokens - 1 {
                let synthesized = Hit(
                    path: hit.path,
                    kind: hit.kind,
                    size: hit.size,
                    mtime: hit.mtime,
                    score: max(hit.score, 1000)
                )
                partialMatches.append(synthesized)
            }
        }

        return !fullMatches.isEmpty ? fullMatches : partialMatches
    }

    private static func passesFilters(hit: Hit, plan: SearchQueryPlan, fileType: String) -> Bool {
        if fileType == "dir" && hit.kind != "dir" {
            return false
        }
        let nameLower = hit.name.lowercased()
        let pathLower = hit.path.lowercased()
        let extLower = hit.url.pathExtension.lowercased()

        for token in plan.preservedTokens {
            if token.hasPrefix("!"), token.count > 1 {
                let excluded = String(token.dropFirst()).lowercased()
                if nameLower.contains(excluded) || pathLower.contains(excluded) {
                    return false
                }
            } else if let colon = token.firstIndex(of: ":") {
                let key = String(token[..<colon]).lowercased()
                let value = String(token[token.index(after: colon)...]).lowercased()
                if key == "ext" {
                    let allowed = Set(
                        value.split(separator: ",").map {
                            $0.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                        })
                    if !allowed.contains(extLower) {
                        return false
                    }
                } else if key == "kind" || key == "type" {
                    if (value == "dir" || value == "folder") && hit.kind != "dir" {
                        return false
                    }
                    if value == "file" && hit.kind == "dir" {
                        return false
                    }
                }
            }
        }
        return true
    }
}
