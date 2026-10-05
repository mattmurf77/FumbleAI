import Foundation

/// "Tell Home": turns something said or typed ("hey we're thinking of getting a new fence in 3 months & wanna spend
/// 10k, could u put in that idea in", "add task of changing hvac every 3 months") into proposed to-dos and projects.
///
/// The text is split into pieces with `ListCapture` (commas, "and then", new lines…), each piece is read for an amount
/// ("$10k", "10,000 dollars", "ten thousand"), a date ("in 3 months", "next week", "by June", "this weekend") and a
/// repeat ("every 3 months", "monthly", "every 90 days"), and what is left becomes the title once filler ("hey",
/// "could you", "add a task of", "we're thinking of getting") is stripped. Pieces that are only filler or details
/// ("could u put in that idea in", "budget is 5k") are folded into the item next to them.
///
/// Kind: a repeat, "task", "remind me" or a filter point to a to-do; money, a far-off date, "idea", "project",
/// "thinking of", "new", "install", "remodel" point to a project. Ties go to a to-do. Pure and deterministic.
public enum SmartCapture {
    public enum Kind: String, CaseIterable, Hashable, Sendable, Codable {
        case todo, project
        public var displayName: String { self == .todo ? "To-Do" : "Project" }
    }

    /// One proposed item. Projects are filed as ideas (`Project.Status.idea`).
    public struct Proposal: Hashable, Sendable {
        public var kind: Kind
        public var title: String
        /// Project estimate (or a to-do's budget, kept in its notes).
        public var amount: Money?
        /// Project target date, or a to-do's due / first date.
        public var date: LocalDate?
        /// To-dos only.
        public var repeatRule: RepeatRule?
        /// The words this item came from.
        public var source: String

        public init(kind: Kind, title: String, amount: Money? = nil, date: LocalDate? = nil, repeatRule: RepeatRule? = nil,
                    source: String = "") {
            self.kind = kind; self.title = title; self.amount = amount; self.date = date; self.repeatRule = repeatRule
            self.source = source
        }

        /// A to-do: due on `date`; a repeat with no date starts `today`; no date and no repeat → "No date".
        public func choreDraft(propertyId: UUID, scope: Scope, today: LocalDate) -> ChoreDraft {
            var notes: String?
            if let amount, !amount.isZero { notes = "Budget: \(amount.formatted(locale: Locale(identifier: "en_US"), showCents: false))" }
            return ChoreDraft(propertyId: propertyId, scope: scope, title: Self.clip(title), notes: notes,
                              repeatRule: repeatRule, startOn: date ?? today, noDueDate: date == nil && repeatRule == nil)
        }

        /// A project idea with the estimate and target date.
        public func projectDraft(propertyId: UUID, scope: Scope) -> ProjectDraft {
            ProjectDraft(propertyId: propertyId, scope: scope, title: Self.clip(title), status: .idea,
                         estCost: amount.flatMap { $0.isZero ? nil : $0 }, targetOn: date)
        }

        static func clip(_ s: String) -> String {
            String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(ListCapture.maxTitleLength))
        }
    }

    // MARK: Entry points

    /// Every item in `text` (one or many).
    public static func proposals(from text: String, today: LocalDate, currency: String = "USD") -> [Proposal] {
        var prepared = text.replacingOccurrences(of: "\u{2019}", with: "'")
        // "10,000" must survive ListCapture's comma split.
        prepared = replace(#"(\d),(\d{3})\b"#, in: prepared, with: "$1$2")
        prepared = replace(#"(\d),(\d{3})\b"#, in: prepared, with: "$1$2")
        // "… and also add …", "… and remind me …" start a new item.
        prepared = replace(#"\s+(?:and\s+)?also\s+(?=(?:add|put|create|make|remind|log|note)\b)"#, in: prepared, with: ", ")
        prepared = replace(#"\s+and\s+(?=(?:add|create|remind me|make a|log a)\b)"#, in: prepared, with: ", ")

        let fragments = ListCapture.items(from: prepared).map { fragment(from: $0, today: today, currency: currency) }

        // Fold filler-only pieces into a neighbour.
        var merged: [Fragment] = []
        var pending: Fragment?
        for var f in fragments {
            if f.title.isEmpty {
                if merged.isEmpty {
                    if let p = pending { pending = p.absorbing(f) } else { pending = f }
                } else {
                    merged[merged.count - 1] = merged[merged.count - 1].absorbing(f)
                }
            } else {
                if let p = pending { f = f.absorbing(p); pending = nil }
                merged.append(f)
            }
        }
        return merged.map { $0.proposal(today: today) }
    }

    /// One item from one piece of text (no splitting); nil when nothing but filler is left.
    public static func parse(_ piece: String, today: LocalDate, currency: String = "USD") -> Proposal? {
        let f = fragment(from: piece, today: today, currency: currency)
        return f.title.isEmpty ? nil : f.proposal(today: today)
    }

    // MARK: Fragment

    struct Fragment {
        var title: String
        var amount: Money?
        var date: LocalDate?
        var rule: RepeatRule?
        var projectScore: Int
        var todoScore: Int
        var source: String

        func absorbing(_ other: Fragment) -> Fragment {
            var f = self
            f.amount = f.amount ?? other.amount
            f.date = f.date ?? other.date
            f.rule = f.rule ?? other.rule
            f.projectScore += other.projectScore
            f.todoScore += other.todoScore
            f.source = [f.source, other.source].filter { !$0.isEmpty }.joined(separator: ", ")
            return f
        }

        func proposal(today: LocalDate) -> Proposal {
            var p = projectScore, t = todoScore
            if amount != nil { p += 2 }
            if rule != nil { t += 4 }
            if let date {
                let days = today.days(until: date)
                if days >= 45 { p += 1 } else if days < 14 { t += 1 }
            }
            let kind: Kind = p > t ? .project : .todo
            return Proposal(kind: kind, title: title, amount: amount, date: date,
                            repeatRule: kind == .todo ? rule : nil, source: source)
        }
    }

    static func fragment(from raw: String, today: LocalDate, currency: String) -> Fragment {
        var s = normalize(raw)
        let lower = s.lowercased()
        var projectScore = score(lower, projectCues)
        var todoScore = score(lower, todoCues)

        let rule = takeRecurrence(&s)
        let amount = takeMoney(&s, currency: currency)
        let date = takeDate(&s, today: today)
        var title = cleanTitle(s)
        if score(title.lowercased(), todoVerbCue) > 0 { todoScore += 1 }
        if isOnlyMeta(title) { title = "" }
        // "Remind me…" is a to-do even with money mentioned; an explicit "as a project" wins over everything.
        if lower.range(of: #"\bas an? (?:project|idea)\b"#, options: .regularExpression) != nil { projectScore += 10 }
        if lower.range(of: #"\bas an? (?:task|to-?do|chore|reminder)\b"#, options: .regularExpression) != nil { todoScore += 10 }
        return Fragment(title: title, amount: amount, date: date, rule: rule, projectScore: projectScore,
                        todoScore: todoScore, source: raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: Normalizing

    static func normalize(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "\u{2018}", with: "'")
        s = s.replacingOccurrences(of: "&", with: " and ")
        s = replace(#"(\d),(\d{3})\b"#, in: s, with: "$1$2")
        let words: [(String, String)] = [
            (#"\bwanna\b"#, "want to"), (#"\bgonna\b"#, "going to"), (#"\bgotta\b"#, "have to"),
            (#"\bu\b"#, "you"), (#"\bur\b"#, "your"), (#"\bpl[sz]\b"#, "please"), (#"\bthx\b"#, "thanks"),
            (#"\bthinkin'?\b"#, "thinking"),
        ]
        for (pattern, with) in words { s = replace(pattern, in: s, with: with) }
        return collapse(s)
    }

    // MARK: Kind cues

    private static let projectCues: [(String, Int)] = [
        (#"\b(?:project|idea|remodel\w*|renovat\w*|redo|overhaul|addition)\b"#, 3),
        (#"\b(?:thinking (?:of|about)|considering|planning (?:on|to)|hoping to|get(?:ting)? a new|buy(?:ing)? a new)\b"#, 2),
        (#"\bnew\b"#, 2),
        (#"\b(?:install\w*|upgrade\w*|build\w*|put in an?|replace the|replacing the|budget\w*|spend\w*|quote|contractor|someday|eventually)\b"#, 2),
    ]
    private static let todoCues: [(String, Int)] = [
        (#"\b(?:task|to-?do|to do|chore|remind me|reminder|don't forget)\b"#, 3),
        (#"\bfilters?\b"#, 3),
        (#"\b(?:tomorrow|today|tonight)\b"#, 1),
    ]
    private static let todoVerbCue: [(String, Int)] = [
        (#"^(?:clean|wash|mow|water|call|pick up|buy|check|change|fix|take out|schedule|vacuum|sweep|empty|pay|test|flush|drain|trim|rake|service|text|email|order|book|dust|mop|wipe|feed|walk|weed|prune|sharpen|reset|refill|restock|return)\b"#, 1),
    ]

    static func score(_ s: String, _ cues: [(String, Int)]) -> Int {
        cues.reduce(0) { $0 + (s.range(of: $1.0, options: [.regularExpression, .caseInsensitive]) != nil ? $1.1 : 0) }
    }

    // MARK: Numbers

    private static let units = ["zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
                                "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13,
                                "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
                                "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60,
                                "seventy": 70, "eighty": 80, "ninety": 90, "a": 1, "an": 1]
    private static let tensWords = "twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety"
    private static let unitWords = "one|two|three|four|five|six|seven|eight|nine"
    private static let smallWords = "ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|\(unitWords)"
    /// A spelled-out number up to the millions: "ten", "twenty five", "fifteen hundred", "ten thousand", "a hundred".
    private static let spelledNumber =
        "(?:(?:\(tensWords))(?:[\\s-](?:\(unitWords)))?|\(smallWords)|an?)(?:[\\s-]+(?:hundred|thousand|million|(?:\(tensWords))(?:[\\s-](?:\(unitWords)))?|\(smallWords)))*"
    /// A count for "every N" / "in N": digits, a spelled number, "a couple of", "a few", "a", "half a".
    private static let count = "(\\d+|a couple of|a couple|couple of|a few|few|several|half an?|(?:\(tensWords))(?:[\\s-](?:\(unitWords)))?|\(smallWords)|an?|other)"

    /// "ten" → 10, "twenty-five" → 25, "fifteen hundred" → 1500, "ten thousand" → 10000, "a couple of" → 2.
    public static func number(_ text: String) -> Int? {
        let t = text.lowercased().trimmingCharacters(in: .whitespaces)
        if let n = Int(t) { return n }
        switch t {
        case "a couple of", "a couple", "couple of", "other": return 2
        case "a few", "few", "several": return 3
        default: break
        }
        let tokens = t.split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init)
        guard !tokens.isEmpty else { return nil }
        var total = 0, current = 0
        for tok in tokens {
            if let v = units[tok] { current += v }
            else if tok == "hundred" { current = max(current, 1) * 100 }
            else if tok == "thousand" { total += max(current, 1) * 1000; current = 0 }
            else if tok == "million" { total += max(current, 1) * 1_000_000; current = 0 }
            else if tok == "and" { continue }
            else { return nil }
        }
        return total + current
    }

    // MARK: Money

    /// The first amount in `text`, if any: "$10k", "10k", "$4,500", "10 thousand dollars", "ten thousand", "5 grand".
    public static func money(in text: String, currency: String = "USD") -> Money? {
        var s = normalize(text)
        return takeMoney(&s, currency: currency)
    }

    private static let moneyFiller: Set<String> = Set([
        "and", "want", "wanted", "to", "spend", "spending", "budget", "budgeted", "of", "about", "around", "roughly",
        "approximately", "maybe", "up", "for", "under", "max", "cost", "costs", "costing", "will", "would", "like",
        "we'd", "i'd", "we", "i", "plan", "planning", "going", "hoping", "with", "a", "is", "be", "should", "it",
        "probably", "say", "least", "at", "most", "no", "more", "than", "just", "over", "less", "or", "so", "the",
        "estimate", "estimated", "price", "priced", "total", "willing", "can", "could", "afford", "allocate", "set",
        "aside", "put", "away", "save", "saving",
    ])

    static func takeMoney(_ s: inout String, currency: String) -> Money? {
        let magnitude: (String?) -> Decimal = { word in
            switch word?.lowercased() {
            case "k", "thousand", "grand": return 1000
            case "m", "mil", "million": return 1_000_000
            default: return 1
            }
        }
        // $10k, $10,000, $1.5 million
        if let m = take(#"\$\s?(\d+(?:\.\d+)?)(?:\s*(k|thousand|grand|m|mil|million)\b)?"#, from: &s, filler: moneyFiller),
           let v = m[1].flatMap({ Decimal(string: $0) }) {
            return Money(major: v * magnitude(m[2]), currency: currency)
        }
        // 10k, 10 thousand (dollars), 5 grand
        if let m = take(#"\b(\d+(?:\.\d+)?)\s*(k|thousand|grand|mil|million)\b(?:\s*(?:dollars|bucks|usd))?"#, from: &s, filler: moneyFiller),
           let v = m[1].flatMap({ Decimal(string: $0) }) {
            return Money(major: v * magnitude(m[2]), currency: currency)
        }
        // 10000 dollars, 500 bucks
        if let m = take(#"\b(\d+(?:\.\d+)?)\s*(?:dollars|bucks|usd)\b"#, from: &s, filler: moneyFiller),
           let v = m[1].flatMap({ Decimal(string: $0) }) {
            return Money(major: v, currency: currency)
        }
        // ten thousand (dollars), fifteen hundred bucks, five grand, a thousand dollars
        let spelled = #"\b("# + spelledNumber + #")(?:\s+(grand|dollars|bucks))?\b"#
        let isAmount: ([String?]) -> Bool = { g in
            guard let words = g[1]?.lowercased(), number(words) != nil else { return false }
            return g[2] != nil || words.contains("hundred") || words.contains("thousand") || words.contains("million")
        }
        if let m = take(spelled, from: &s, filler: moneyFiller, accept: isAmount), let words = m[1], let n = number(words) {
            let value = m[2]?.lowercased() == "grand" ? Decimal(n) * 1000 : Decimal(n)
            return Money(major: value, currency: currency)
        }
        return nil
    }

    // MARK: Recurrence

    /// The first repeat in `text`: "every 3 months", "monthly", "every other week", "every 90 days", "annually".
    public static func recurrence(in text: String) -> RepeatRule? {
        var s = normalize(text)
        return takeRecurrence(&s)
    }

    private static let recurrenceFiller: Set<String> = Set(["and", "repeat", "repeating", "repeats", "recurring", "once", "it", "do", "that", "to", "be", "done", "should"])
    private static let weekdayNames = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

    static func rule(unit: String, every n: Int) -> RepeatRule? {
        guard n >= 1 else { return nil }
        switch unit.lowercased() {
        case "day": return n == 1 ? .daily : .everyNDays(n)
        case "week": return RepeatRule(freq: .weekly, interval: n)
        case "month": return RepeatRule(freq: .monthly, interval: n)
        case "quarter", "season": return RepeatRule(freq: .monthly, interval: 3 * n)
        case "year": return RepeatRule(freq: .monthly, interval: 12 * n)
        default: return nil
        }
    }

    static func takeRecurrence(_ s: inout String) -> RepeatRule? {
        let units = "(day|week|month|year|quarter|season)s?"
        // every 3 months, every other week, every couple of weeks, each 90 days
        if let m = take(#"\b(?:every|each)\s+"# + count + #"\s+"# + units + #"\b"#, from: &s, filler: recurrenceFiller),
           let c = m[1], let u = m[2] {
            let n = c.lowercased().hasPrefix("half") ? nil : number(c)
            if c.lowercased().hasPrefix("half"), u.lowercased() == "year" { return RepeatRule(freq: .monthly, interval: 6) }
            if let n { return rule(unit: u, every: n) }
        }
        // every month, each week, once a year, once per quarter
        if let m = take(#"\b(?:every|each|once an?|once per|once every)\s+(day|week|month|year|quarter|season)\b"#, from: &s, filler: recurrenceFiller),
           let u = m[1] {
            return rule(unit: u, every: 1)
        }
        // every saturday
        if let m = take(#"\b(?:every|each)\s+("# + weekdayNames.joined(separator: "|") + #")s?\b"#, from: &s, filler: recurrenceFiller),
           let d = m[1], let i = weekdayNames.firstIndex(of: d.lowercased()) {
            return .weekly([i + 1])
        }
        // every fall, each spring → once a year
        if take(#"\b(?:every|each)\s+(?:spring|summer|fall|autumn|winter)\b"#, from: &s, filler: recurrenceFiller) != nil {
            return RepeatRule(freq: .monthly, interval: 12)
        }
        // twice a year / twice a month
        if let m = take(#"\btwice (?:a|per)\s+(year|month)\b"#, from: &s, filler: recurrenceFiller), let u = m[1] {
            return u.lowercased() == "year" ? RepeatRule(freq: .monthly, interval: 6) : RepeatRule(freq: .weekly, interval: 2)
        }
        // monthly, weekly, annually …
        if let m = take(#"\b(daily|nightly|weekly|biweekly|bi-weekly|fortnightly|monthly|bimonthly|bi-monthly|quarterly|yearly|annually|semi-?annually)\b"#, from: &s, filler: recurrenceFiller),
           let w = m[1] {
            switch w.lowercased() {
            case "daily", "nightly": return .daily
            case "weekly": return RepeatRule(freq: .weekly, interval: 1)
            case "biweekly", "bi-weekly", "fortnightly": return RepeatRule(freq: .weekly, interval: 2)
            case "monthly": return RepeatRule(freq: .monthly, interval: 1)
            case "bimonthly", "bi-monthly": return RepeatRule(freq: .monthly, interval: 2)
            case "quarterly": return RepeatRule(freq: .monthly, interval: 3)
            case "semiannually", "semi-annually": return RepeatRule(freq: .monthly, interval: 6)
            default: return RepeatRule(freq: .monthly, interval: 12)
            }
        }
        return nil
    }

    // MARK: Dates

    /// The first date in `text`, relative to `today`: "in 3 months", "next week", "tomorrow", "by June", "this weekend".
    public static func date(in text: String, today: LocalDate) -> LocalDate? {
        var s = normalize(text)
        return takeDate(&s, today: today)
    }

    private static let dateFiller: Set<String> = Set([
        "sometime", "maybe", "around", "about", "probably", "and", "starting", "start", "it", "do", "due", "for",
        "from", "hopefully", "like", "roughly", "approximately", "or", "so", "the", "early", "late", "done", "be",
        "should", "want", "to", "get", "target", "targeting", "aim", "aiming", "is", "on",
    ])
    private static let monthNames = ["january", "february", "march", "april", "may", "june", "july", "august",
                                     "september", "october", "november", "december"]
    private static let monthAbbrev = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    static func takeDate(_ s: inout String, today: LocalDate) -> LocalDate? {
        // in 3 months, within two weeks, in a couple of weeks, in a year
        if let m = take(#"\b(?:in|within|after)\s+(?:about\s+|around\s+|roughly\s+|like\s+)?"# + count + #"\s+(day|week|month|year)s?(?:'?\s*time)?\b"#,
                        from: &s, filler: dateFiller),
           let c = m[1], let u = m[2] {
            let cl = c.lowercased()
            if cl.hasPrefix("half") {
                return u.lowercased() == "year" ? today.adding(months: 6) : u.lowercased() == "month" ? today.adding(days: 15) : nil
            }
            if cl != "other", let n = number(c) { return offset(today, unit: u, by: n) }
        }
        // next week / month / year
        if let m = take(#"\b(?:next|in a)\s+(week|month|year)\b"#, from: &s, filler: dateFiller), let u = m[1] {
            return offset(today, unit: u, by: 1)
        }
        // end of the week / month / year
        if let m = take(#"\b(?:by\s+|before\s+)?(?:the\s+)?end of (?:the|this)\s+(week|month|year)\b"#, from: &s, filler: dateFiller), let u = m[1] {
            switch u.lowercased() {
            case "week": return today.adding(days: (7 - today.weekday) % 7)        // Saturday
            case "month": return LocalDate(today.year, today.month, today.lastDayOfMonth)
            default: return LocalDate(today.year, 12, 31)
            }
        }
        // tomorrow / today / tonight
        if let m = take(#"\b(tomorrow|today|tonight)\b"#, from: &s, filler: dateFiller), let w = m[1] {
            return w.lowercased() == "tomorrow" ? today.adding(days: 1) : today
        }
        // this weekend / next weekend / over the weekend
        if let m = take(#"\b(this|next|over the|on the)\s+weekend\b"#, from: &s, filler: dateFiller), let w = m[1] {
            let saturday = today.adding(days: (7 - today.weekday) % 7)
            return w.lowercased() == "next" ? saturday.adding(days: 7) : saturday
        }
        // by June, in March 2027, before october
        let months = (monthNames + monthAbbrev.filter { $0 != "may" }).joined(separator: "|")
        if let m = take(#"\b(?:by|in|before|around|until|for|this|next|early|late|mid|end of|beginning of)\s+("# + months + #")\.?(?:\s+(\d{4}))?\b"#,
                        from: &s, filler: dateFiller),
           let name = m[1] {
            let key = String(name.lowercased().prefix(3))
            guard let month = monthAbbrev.firstIndex(of: key).map({ $0 + 1 }) else { return nil }
            if let y = m[2].flatMap(Int.init) { return LocalDate(y, month, 1) }
            if month == today.month { return today }
            let candidate = LocalDate(today.year, month, 1)
            return candidate < today ? LocalDate(today.year + 1, month, 1) : candidate
        }
        // next spring, this summer, in the fall
        if let m = take(#"\b(?:this|next|in the|by|in|by the|before)\s+(spring|summer|fall|autumn|winter)\b"#, from: &s, filler: dateFiller),
           let season = m[1] {
            let startMonth: Int
            switch season.lowercased() {
            case "spring": startMonth = 3
            case "summer": startMonth = 6
            case "fall", "autumn": startMonth = 9
            default: startMonth = 12
            }
            let candidate = LocalDate(today.year, startMonth, 1)
            return candidate <= today ? LocalDate(today.year + 1, startMonth, 1) : candidate
        }
        // on saturday, next tuesday, this friday
        if let m = take(#"\b(on|next|this|by)\s+("# + weekdayNames.joined(separator: "|") + #")\b"#, from: &s, filler: dateFiller),
           let prefix = m[1], let d = m[2], let i = weekdayNames.firstIndex(of: d.lowercased()) {
            var days = ((i + 1) - today.weekday + 7) % 7
            if days == 0 && prefix.lowercased() != "this" { days = 7 }
            return today.adding(days: days)
        }
        return nil
    }

    static func offset(_ today: LocalDate, unit: String, by n: Int) -> LocalDate {
        switch unit.lowercased() {
        case "day": return today.adding(days: n)
        case "week": return today.adding(days: 7 * n)
        case "month": return today.adding(months: n)
        default: return today.adding(months: 12 * n)
        }
    }

    // MARK: Title

    private static let leadingFiller: [String] = [
        #"^(?:hey|hi|hello|ok|okay|so|um+|uh+|er+|alright|all right|yeah|yes|well|oh|and|also|then|plus)\b[\s,.!:-]*"#,
        #"^home(?: blueprint)?\s*[,:]\s*"#,
        #"^(?:please)\b[\s,]*"#,
        #"^(?:could|can|would|will)\s+you\s+(?:please\s+)?(?:(?:add|put|create|make|log|note|save|set up|schedule|remember|jot|write|throw|stick|file)(?:\s+(?:in|down|up|on))?\b\s*)?"#,
        #"^(?:i'm|i am|we're|we are|we've been|i've been|we were|i was|been)?\s*(?:thinking|considering|planning|hoping|looking|wanting)\s*(?:of|about|on|to|at|into)?\s*(?:(?:getting|doing|buying|adding|installing|putting in|having|redoing|get|do|buy|add|install|put in|have)\s+)?"#,
        #"^(?:i'd|we'd|i would|we would)\s+(?:like|love)\s+to\s+(?:(?:get|do|have|buy)\s+)?"#,
        #"^(?:i|we)\s+(?:really\s+)?(?:need|want|have|got|should|must|ought)\s+(?:to\s+)?"#,
        #"^(?:(?:please\s+)?(?:add|create|make|put|log|note|save|set up|schedule|start|new))\s+(?:(?:a|an|another|the|this|that)\s+)?(?:(?:new|recurring|repeating|quick)\s+)?(?:task|to-?do|to do|chore|reminder|project|idea|job)s?\b\s*(?:(?:of|to|for|about|called|named|that says|saying)\b)?[\s:,-]*"#,
        #"^(?:(?:a|an|the|new)\s+)?(?:task|to-?do|chore|reminder|project|idea|job)\s*(?:(?:to|of|for|about)\b|:|-)\s*"#,
        #"^(?:remind me|reminder|remember|don't forget|do not forget)\s+(?:to|about|that)?\s*"#,
        #"^(?:maybe|possibly|perhaps|eventually|someday|one day|probably)\b\s*"#,
        #"^(?:get|getting|buy|buying|add|adding|note|jot down)\s+(?:(?:a|an|some|the)\s+)?(?=new\b)"#,
    ]
    private static let trailingFiller: [String] = [
        #"[\s,]*(?:could|can|would|will)\s+you\b.*$"#,
        #"[\s,]*\b(?:and\s+)?(?:put|add|log|save|file)\s+(?:that|this|it)\b.*$"#,
        #"[\s,]*\b(?:please|thanks|thank you|for me|for us|to (?:the|my|our) list|on (?:the|my|our) list|in here|in there|in the app|as (?:an? )?(?:idea|project|task|to-?do|to do|chore|reminder))[\s.!]*$"#,
    ]
    private static let edgeWords: Set<String> = Set([
        "and", "but", "so", "then", "also", "to", "of", "for", "with", "that", "which", "in", "on", "at", "by", "um",
        "uh", "like", "just", "or", "it", "is", "are", "be", "we", "i", "want", "please",
    ])
    private static let articles: Set<String> = Set(["a", "an", "the", "some", "our", "my"])
    private static let metaWords: Set<String> = Set([
        "budget", "target", "date", "cost", "costs", "price", "estimate", "is", "be", "about", "around", "roughly",
        "maybe", "spend", "want", "to", "should", "would", "will", "it", "that", "this", "idea", "task", "project",
        "we", "i", "our", "and", "the", "a", "an", "so", "put", "in", "add", "could", "can", "you", "please", "thanks",
        "thank", "also", "like", "for", "of", "with", "on", "at", "by", "then", "just", "um", "uh", "hey", "okay",
        "ok", "yeah", "hi", "hello", "there", "list", "app", "here", "me", "us", "do", "it's", "its", "that's",
        "repeat", "repeating", "recurring", "starting", "due", "reminder", "to-do", "todo", "chore", "note", "save",
        "log", "home", "around", "probably", "say", "let's", "lets", "something", "thing", "one", "too", "as",
        "remind", "remember", "plan", "planning", "start", "aim", "target", "it'd", "would", "nice", "great", "cool",
    ])
    private static let gerunds: [String: String] = [
        "changing": "change", "replacing": "replace", "cleaning": "clean", "checking": "check", "fixing": "fix",
        "painting": "paint", "mowing": "mow", "washing": "wash", "servicing": "service", "flushing": "flush",
        "draining": "drain", "testing": "test", "trimming": "trim", "sealing": "seal", "calling": "call",
        "scheduling": "schedule", "getting": "get", "buying": "buy", "installing": "install", "repairing": "repair",
        "inspecting": "inspect", "raking": "rake", "watering": "water", "vacuuming": "vacuum", "sweeping": "sweep",
        "organizing": "organize", "power-washing": "power-wash", "pressure-washing": "pressure-wash",
        "emptying": "empty", "dusting": "dust", "mopping": "mop", "wiping": "wipe", "weeding": "weed",
        "pruning": "prune", "fertilizing": "fertilize", "staining": "stain", "caulking": "caulk", "ordering": "order",
        "booking": "book", "paying": "pay", "taking": "take", "picking": "pick", "updating": "update",
        "refilling": "refill", "resetting": "reset", "rotating": "rotate", "descaling": "descale", "defrosting": "defrost",
        "building": "build", "adding": "add", "redoing": "redo", "remodeling": "remodel", "refinishing": "refinish",
        "upgrading": "upgrade", "planting": "plant", "removing": "remove", "hiring": "hire", "setting": "set",
    ]
    private static let acronyms: [String: String] = [
        "hvac": "HVAC", "ac": "AC", "a/c": "A/C", "tv": "TV", "diy": "DIY", "hoa": "HOA", "gfci": "GFCI", "led": "LED",
        "leds": "LEDs", "usb": "USB", "wifi": "Wi-Fi", "wi-fi": "Wi-Fi", "erv": "ERV", "hrv": "HRV", "adu": "ADU",
        "ev": "EV", "co2": "CO2",
    ]

    static func cleanTitle(_ input: String) -> String {
        var s = collapse(input)
        s = replace(#"\b(?:that|this)\s+(?:idea|one)\b"#, in: s, with: " ")
        s = collapse(s)
        var changed = true
        var guardCount = 0
        while changed && guardCount < 12 {
            changed = false
            guardCount += 1
            let before = s
            for p in leadingFiller { s = replace(p, in: s, with: "") }
            for p in trailingFiller { s = replace(p, in: s, with: "") }
            s = stripEdges(collapse(s))
            if s != before { changed = true }
        }
        var words = s.split(separator: " ").map(String.init)
        if let first = words.first, articles.contains(first.lowercased()), words.count > 1 { words.removeFirst() }
        if let first = words.first, let base = gerunds[first.lowercased()] { words[0] = base }
        words = words.map { w in
            let core = w.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:"))
            if let a = acronyms[core.lowercased()] { return w.replacingOccurrences(of: core, with: a) }
            return w
        }
        var out = words.joined(separator: " ")
        while let last = out.last, ".,;:!?-".contains(last) { out.removeLast() }
        out = out.trimmingCharacters(in: .whitespaces)
        guard let f = out.first else { return "" }
        return Proposal.clip(f.uppercased() + out.dropFirst())
    }

    static func stripEdges(_ s: String) -> String {
        var words = s.split(separator: " ").map(String.init)
        func bare(_ w: String) -> String { w.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:-")) }
        while let f = words.first, edgeWords.contains(bare(f)) || bare(f).isEmpty { words.removeFirst() }
        while let l = words.last, edgeWords.contains(bare(l)) || articles.contains(bare(l)) || bare(l).isEmpty { words.removeLast() }
        return words.joined(separator: " ")
    }

    static func isOnlyMeta(_ title: String) -> Bool {
        let words = title.lowercased().split(whereSeparator: { " ,.!?;:".contains($0) }).map(String.init)
        return words.allSatisfy { metaWords.contains($0) }
    }

    // MARK: Regex helpers

    static func regex(_ pattern: String) -> NSRegularExpression {
        // Patterns are fixed literals in this file (covered by tests), so compiling cannot fail.
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    static func replace(_ pattern: String, in s: String, with template: String) -> String {
        regex(pattern).stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    static func collapse(_ s: String) -> String {
        s.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    /// Removes the first match of `pattern` from `s` plus filler words right before it ("want to spend" before "10k").
    /// Returns the capture groups (index 0 = whole match), or nil when there is no match.
    /// `accept` can skip a match (the first acceptable one is taken).
    static func take(_ pattern: String, from s: inout String, filler: Set<String>,
                     accept: ([String?]) -> Bool = { _ in true }) -> [String?]? {
        let r = regex(pattern)
        var found: (Range<String.Index>, [String?])?
        for m in r.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let whole = Range(m.range, in: s) else { continue }
            var groups: [String?] = []
            for i in 0..<m.numberOfRanges {
                if let r = Range(m.range(at: i), in: s) { groups.append(String(s[r])) } else { groups.append(nil) }
            }
            if accept(groups) { found = (whole, groups); break }
        }
        guard let (whole, groups) = found else { return nil }
        var prefix = s[..<whole.lowerBound].split(separator: " ").map(String.init)
        while let last = prefix.last, filler.contains(last.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",.;:"))) {
            prefix.removeLast()
        }
        let suffix = String(s[whole.upperBound...])
        s = collapse(prefix.joined(separator: " ") + " " + suffix)
        return groups
    }
}
