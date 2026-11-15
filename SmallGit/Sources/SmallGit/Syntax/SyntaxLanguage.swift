import Foundation

/// A language the compare views know how to colour.
///
/// Deliberately a closed set of hand-written specs rather than a dependency.
/// The alternative was Highlightr, which wraps highlight.js in JavaScriptCore
/// — ~190 languages for the cost of a JS engine in-process and a per-line
/// bridge crossing on a view that renders thousands of lines. A scanner over
/// `[Character]` is a few hundred lines, has no runtime to warm up, and is
/// testable without a browser engine.
///
/// Adding a language is a `Spec` and a case: no scanner changes.
enum SyntaxLanguage: String, Sendable, Hashable, CaseIterable {
    case swift
    case objectiveC
    case c
    case cpp
    case java
    case kotlin
    case csharp
    case javascript
    case typescript
    case go
    case rust
    case python
    case ruby
    case shell
    case sql
    case json
    case yaml
    case css

    /// Best guess from a file path, or `nil` when the file should be left
    /// uncoloured.
    ///
    /// `nil` is a real answer, not a failure: colouring a language we don't
    /// actually parse — Markdown's prose, an HTML file's embedded everything —
    /// puts keywords and strings in the wrong places, which is worse in a diff
    /// than plain text, because the eye reads the colour as meaning.
    init?(path: String) {
        let name = (path as NSString).lastPathComponent
        if let byName = Self.byFileName[name.lowercased()] {
            self = byName
            return
        }
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, let byExtension = Self.byExtension[ext] else { return nil }
        self = byExtension
    }

    /// Files whose language is in the name rather than an extension.
    private static let byFileName: [String: SyntaxLanguage] = [
        "podfile": .ruby,
        "fastfile": .ruby,
        "gemfile": .ruby,
        "rakefile": .ruby,
        "brewfile": .ruby,
        "package.json": .json,
        ".zshrc": .shell,
        ".bashrc": .shell,
        ".bash_profile": .shell,
        ".profile": .shell
    ]

    private static let byExtension: [String: SyntaxLanguage] = [
        "swift": .swift,
        // `.h` is ambiguous between C, C++ and Objective-C headers, and no
        // extension can settle it. Objective-C wins because its spec is a
        // superset — it carries the C keywords too — so a plain C header is
        // still coloured correctly, while the reverse would silently drop
        // every `@property` and `@interface` in an iOS project.
        "h": .objectiveC,
        "m": .objectiveC,
        "mm": .objectiveC,
        "c": .c,
        "cc": .cpp, "cpp": .cpp, "cxx": .cpp, "hpp": .cpp, "hh": .cpp, "hxx": .cpp,
        "java": .java,
        "kt": .kotlin, "kts": .kotlin,
        "cs": .csharp,
        "js": .javascript, "jsx": .javascript, "mjs": .javascript, "cjs": .javascript,
        "ts": .typescript, "tsx": .typescript,
        "go": .go,
        "rs": .rust,
        "py": .python, "pyi": .python,
        "rb": .ruby,
        "sh": .shell, "bash": .shell, "zsh": .shell, "ksh": .shell,
        "sql": .sql,
        "json": .json,
        "yml": .yaml, "yaml": .yaml,
        "css": .css, "scss": .css, "less": .css
    ]

    var spec: Spec { Self.specs[self] ?? Spec() }

    /// Built once. `Spec` holds prepared `Set`s and `[Character]` markers, so
    /// rebuilding one per line — which is what a computed property would do —
    /// would cost far more than the scan it feeds.
    private static let specs: [SyntaxLanguage: Spec] = {
        var out: [SyntaxLanguage: Spec] = [:]
        for language in SyntaxLanguage.allCases {
            out[language] = language.makeSpec()
        }
        return out
    }()
}

// MARK: - Spec

extension SyntaxLanguage {

    /// Everything the scanner needs to know about one language.
    ///
    /// Comment and string markers are stored pre-split into `[Character]` so
    /// the scanner never converts a `String` mid-loop.
    struct Spec: Sendable {
        var keywords: Set<String> = []
        /// Built-in type names. Anything not listed here can still be typed by
        /// `capitalisedIsType`.
        var types: Set<String> = []
        /// Identifiers that are values rather than syntax — `nil`, `YES`,
        /// `None`, `self`. Coloured as keywords; separate only so the lists
        /// stay readable.
        var constants: Set<String> = []
        /// Lowercase the identifier before looking it up. For SQL, where
        /// `SELECT` and `select` are the same word.
        var caseInsensitiveKeywords: Bool = false

        var lineComments: [[Character]] = []
        var blockCommentOpen: [Character]?
        var blockCommentClose: [Character]?
        /// Rust and Swift count `/*` inside a block comment; C does not, so
        /// `/* /* */` ends there.
        var nestedBlockComments: Bool = false

        var stringDelimiters: Set<Character> = ["\""]
        /// Delimiters that open a string running past the end of the line —
        /// Python's `"""`, Swift's `"""`, Go's backtick.
        var multilineStringDelimiters: [[Character]] = []
        /// `\` nearly everywhere. `nil` where a backslash is a literal
        /// character, so `"C:\"` doesn't swallow the rest of the file.
        var escape: Character? = "\\"

        /// Sigils that turn the following word into a directive: `#` for the C
        /// preprocessor and Swift's `#if`, `@` for Objective-C's `@interface`,
        /// Swift's `@objc`, Java's annotations, Python's decorators.
        var directiveSigils: Set<Character> = []
        /// Sigils that belong to the string that follows them, so Objective-C's
        /// `@"…"` colours as one literal rather than a directive and a string.
        var stringSigils: Set<Character> = []
        /// After `#import` / `#include`, colour `<stdio.h>` as a string. Only
        /// true where `<` is otherwise unambiguous at that position.
        var angleBracketIncludes: Bool = false

        /// Words after which the next identifier is a name being *declared*,
        /// so it is a type whatever else it looks like: `class Foo`,
        /// `@interface Foo`, `struct Foo`.
        ///
        /// This exists because the "followed by `(`" rule is otherwise right
        /// far more often than it is wrong, and the place it is wrong is
        /// exactly here — an Objective-C class extension is written
        /// `@interface Foo()`, which is a declaration wearing a call's shape.
        /// Directive forms are stored with their sigil, since that is how the
        /// scanner sees them.
        var declarationKeywords: Set<String> = []

        /// Characters that may appear inside an identifier beyond the usual
        /// letters, digits, `_` and `$`. Ruby's `empty?` and `save!` need this;
        /// no C-family language may have it, since `?` and `!` are operators
        /// there and `cond?a:b` would scan as one word.
        var extraIdentifierCharacters: Set<Character> = []

        /// Treat a capitalised identifier as a type name. Right for Cocoa,
        /// Swift, Java and Go, whose types are capitalised by convention and
        /// whose constants are not. Wrong for languages that SHOUT their
        /// constants, which is why it is off for C and shell.
        var capitalisedIsType: Bool = false
    }
}

// MARK: - The specs

private extension SyntaxLanguage {

    func makeSpec() -> Spec {
        switch self {
        case .swift:      return Self.swiftSpec
        case .objectiveC: return Self.objectiveCSpec
        case .c:          return Self.cSpec
        case .cpp:        return Self.cppSpec
        case .java:       return Self.javaSpec
        case .kotlin:     return Self.kotlinSpec
        case .csharp:     return Self.csharpSpec
        case .javascript: return Self.javascriptSpec(typed: false)
        case .typescript: return Self.javascriptSpec(typed: true)
        case .go:         return Self.goSpec
        case .rust:       return Self.rustSpec
        case .python:     return Self.pythonSpec
        case .ruby:       return Self.rubySpec
        case .shell:      return Self.shellSpec
        case .sql:        return Self.sqlSpec
        case .json:       return Self.jsonSpec
        case .yaml:       return Self.yamlSpec
        case .css:        return Self.cssSpec
        }
    }

    /// `//` line comments and `/* … */` blocks — the shape shared by every
    /// C-descended language here.
    static func cStyleComments(_ spec: inout Spec, nested: Bool = false) {
        spec.lineComments = [Array("//")]
        spec.blockCommentOpen = Array("/*")
        spec.blockCommentClose = Array("*/")
        spec.nestedBlockComments = nested
    }

    static var swiftSpec: Spec {
        var spec = Spec()
        cStyleComments(&spec, nested: true)
        spec.keywords = [
            "associatedtype", "class", "deinit", "enum", "extension", "fileprivate",
            "func", "import", "init", "inout", "internal", "let", "open", "operator",
            "private", "precedencegroup", "protocol", "public", "rethrows", "static",
            "struct", "subscript", "typealias", "var", "actor", "macro", "package",
            "break", "case", "catch", "continue", "default", "defer", "do", "else",
            "fallthrough", "for", "guard", "if", "in", "repeat", "return", "switch",
            "throw", "throws", "try", "where", "while", "async", "await", "as", "is",
            "some", "any", "each", "borrowing", "consuming",
            "get", "set", "willSet", "didSet", "lazy", "weak", "unowned", "final",
            "override", "required", "convenience", "mutating", "nonmutating",
            "indirect", "dynamic", "optional", "throwing", "nonisolated", "isolated",
            "distributed"
        ]
        spec.constants = ["nil", "true", "false", "self", "Self", "super"]
        spec.types = [
            "Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16",
            "UInt32", "UInt64", "Double", "Float", "CGFloat", "Bool", "String",
            "Character", "Void", "Any", "AnyObject", "Never"
        ]
        spec.multilineStringDelimiters = [Array("\"\"\"")]
        spec.directiveSigils = ["@", "#"]
        spec.declarationKeywords = [
            "class", "struct", "enum", "protocol", "extension", "actor",
            "typealias", "associatedtype"
        ]
        spec.capitalisedIsType = true
        return spec
    }

    static var objectiveCSpec: Spec {
        var spec = cSpec
        spec.keywords.formUnion([
            "in", "out", "inout", "bycopy", "byref", "oneway", "self", "super",
            "__strong", "__weak", "__unsafe_unretained", "__autoreleasing",
            "__block", "__bridge", "__bridge_transfer", "__bridge_retained",
            "__kindof", "nonnull", "nullable", "_Nullable", "_Nonnull",
            "atomic", "nonatomic", "strong", "weak", "copy", "assign", "retain",
            "readonly", "readwrite", "getter", "setter", "typeof", "__typeof__"
        ])
        spec.constants.formUnion(["nil", "Nil", "YES", "NO", "self", "super", "_cmd"])
        spec.types.formUnion(["BOOL", "id", "instancetype", "Class", "SEL", "IMP"])
        // `@` before a quote is part of the literal (`@"text"`); before a word
        // it opens a directive (`@interface`). The scanner picks by lookahead.
        spec.directiveSigils = ["#", "@"]
        spec.stringSigils = ["@"]
        spec.declarationKeywords = [
            "@interface", "@implementation", "@protocol", "@class", "struct",
            "enum", "union"
        ]
        // Cocoa's naming convention is the whole reason this heuristic pays:
        // NSString, UIView, CGRect and every project class light up without a
        // symbol table.
        spec.capitalisedIsType = true
        return spec
    }

    static var cSpec: Spec {
        var spec = Spec()
        cStyleComments(&spec)
        spec.keywords = [
            "auto", "break", "case", "const", "continue", "default", "do", "else",
            "enum", "extern", "for", "goto", "if", "inline", "register", "restrict",
            "return", "sizeof", "static", "struct", "switch", "typedef", "union",
            "volatile", "while", "_Atomic", "_Static_assert", "_Generic"
        ]
        spec.types = [
            "char", "double", "float", "int", "long", "short", "signed", "unsigned",
            "void", "bool", "_Bool", "size_t", "ssize_t", "ptrdiff_t", "uint8_t",
            "uint16_t", "uint32_t", "uint64_t", "int8_t", "int16_t", "int32_t",
            "int64_t", "FILE", "va_list"
        ]
        spec.constants = ["NULL", "true", "false", "TRUE", "FALSE"]
        spec.stringDelimiters = ["\"", "'"]
        spec.directiveSigils = ["#"]
        spec.angleBracketIncludes = true
        return spec
    }

    static var cppSpec: Spec {
        var spec = cSpec
        spec.keywords.formUnion([
            "alignas", "alignof", "and", "asm", "catch", "class", "concept",
            "constexpr", "consteval", "constinit", "const_cast", "co_await",
            "co_return", "co_yield", "decltype", "delete", "dynamic_cast",
            "explicit", "export", "friend", "mutable", "namespace", "new",
            "noexcept", "not", "operator", "or", "private", "protected", "public",
            "reinterpret_cast", "requires", "static_assert", "static_cast",
            "template", "this", "thread_local", "throw", "try", "typeid",
            "typename", "using", "virtual", "xor"
        ])
        spec.constants.formUnion(["nullptr", "this"])
        spec.types.formUnion(["wchar_t", "char8_t", "char16_t", "char32_t", "auto"])
        spec.declarationKeywords = ["class", "struct", "enum", "union", "namespace"]
        spec.capitalisedIsType = true
        return spec
    }

    static var javaSpec: Spec {
        var spec = Spec()
        cStyleComments(&spec)
        spec.keywords = [
            "abstract", "assert", "break", "case", "catch", "class", "const",
            "continue", "default", "do", "else", "enum", "extends", "final",
            "finally", "for", "goto", "if", "implements", "import", "instanceof",
            "interface", "native", "new", "package", "private", "protected",
            "public", "return", "static", "strictfp", "super", "switch",
            "synchronized", "this", "throw", "throws", "transient", "try", "var",
            "volatile", "while", "record", "sealed", "permits", "yield"
        ]
        spec.types = [
            "boolean", "byte", "char", "double", "float", "int", "long", "short",
            "void", "String", "Object", "Integer", "Boolean", "Double", "Long"
        ]
        spec.constants = ["true", "false", "null", "this", "super"]
        spec.stringDelimiters = ["\"", "'"]
        spec.multilineStringDelimiters = [Array("\"\"\"")]
        spec.directiveSigils = ["@"]
        spec.declarationKeywords = ["class", "interface", "enum", "record"]
        spec.capitalisedIsType = true
        return spec
    }

    static var kotlinSpec: Spec {
        var spec = Spec()
        cStyleComments(&spec, nested: true)
        spec.keywords = [
            "package", "import", "class", "interface", "fun", "val", "var", "if",
            "else", "when", "for", "while", "do", "return", "break", "continue",
            "object", "companion", "data", "sealed", "enum", "annotation", "inner",
            "override", "open", "abstract", "final", "private", "protected",
            "public", "internal", "lateinit", "init", "constructor", "this",
            "super", "is", "as", "in", "out", "by", "get", "set", "suspend",
            "typealias", "reified", "inline", "crossinline", "noinline", "vararg",
            "operator", "infix", "tailrec", "external", "expect", "actual"
        ]
        spec.types = [
            "Int", "Long", "Short", "Byte", "Float", "Double", "Boolean", "Char",
            "String", "Unit", "Any", "Nothing", "Array", "List", "Map", "Set"
        ]
        spec.constants = ["true", "false", "null", "this", "super", "it"]
        spec.multilineStringDelimiters = [Array("\"\"\"")]
        spec.directiveSigils = ["@"]
        spec.declarationKeywords = ["class", "interface", "object", "typealias"]
        spec.capitalisedIsType = true
        return spec
    }

    static var csharpSpec: Spec {
        var spec = Spec()
        cStyleComments(&spec)
        spec.keywords = [
            "abstract", "as", "base", "break", "case", "catch", "checked", "class",
            "const", "continue", "default", "delegate", "do", "else", "enum",
            "event", "explicit", "extern", "finally", "fixed", "for", "foreach",
            "goto", "if", "implicit", "in", "interface", "internal", "is", "lock",
            "namespace", "new", "operator", "out", "override", "params", "private",
            "protected", "public", "readonly", "ref", "return", "sealed", "sizeof",
            "stackalloc", "static", "struct", "switch", "this", "throw", "try",
            "typeof", "unchecked", "unsafe", "using", "var", "virtual", "volatile",
            "while", "async", "await", "record", "yield", "get", "set", "init"
        ]
        spec.types = [
            "bool", "byte", "char", "decimal", "double", "float", "int", "long",
            "object", "sbyte", "short", "string", "uint", "ulong", "ushort", "void",
            "dynamic", "nint", "nuint"
        ]
        spec.constants = ["true", "false", "null", "this", "base", "value"]
        spec.stringDelimiters = ["\"", "'"]
        // `#region` / `#if` only. `[` is not a sigil here even though
        // attributes are written `[Serializable]` — it is also the indexing
        // operator, so `items[index]` would colour `index` as a directive.
        spec.directiveSigils = ["#"]
        spec.declarationKeywords = [
            "class", "interface", "struct", "enum", "record", "namespace", "delegate"
        ]
        spec.capitalisedIsType = true
        return spec
    }

    /// One spec for both JavaScript and TypeScript — TS is JS plus the type
    /// vocabulary, and mixing them costs nothing on a `.js` file that never
    /// writes `interface`.
    static func javascriptSpec(typed: Bool) -> Spec {
        var spec = Spec()
        cStyleComments(&spec)
        spec.keywords = [
            "async", "await", "break", "case", "catch", "class", "const",
            "continue", "debugger", "default", "delete", "do", "else", "export",
            "extends", "finally", "for", "from", "function", "get", "if", "import",
            "in", "instanceof", "let", "new", "of", "return", "set", "static",
            "super", "switch", "this", "throw", "try", "typeof", "var", "void",
            "while", "with", "yield"
        ]
        if typed {
            spec.keywords.formUnion([
                "abstract", "as", "declare", "enum", "implements", "interface",
                "is", "keyof", "namespace", "private", "protected", "public",
                "readonly", "satisfies", "type"
            ])
            spec.types = [
                "any", "boolean", "never", "number", "object", "string", "symbol",
                "undefined", "unknown", "void", "bigint"
            ]
        }
        spec.constants = ["true", "false", "null", "undefined", "this", "NaN", "Infinity"]
        spec.stringDelimiters = ["\"", "'"]
        // Template literals are listed as multiline because they genuinely run
        // across lines. Their `${…}` interpolation is coloured as part of the
        // string, which is what most editors settle for too.
        spec.multilineStringDelimiters = [Array("`")]
        spec.directiveSigils = ["@"]
        spec.declarationKeywords = ["class", "interface", "enum", "namespace"]
        spec.capitalisedIsType = true
        return spec
    }

    static var goSpec: Spec {
        var spec = Spec()
        cStyleComments(&spec)
        spec.keywords = [
            "break", "case", "chan", "const", "continue", "default", "defer",
            "else", "fallthrough", "for", "func", "go", "goto", "if", "import",
            "interface", "map", "package", "range", "return", "select", "struct",
            "switch", "type", "var"
        ]
        spec.types = [
            "bool", "byte", "complex64", "complex128", "error", "float32",
            "float64", "int", "int8", "int16", "int32", "int64", "rune", "string",
            "uint", "uint8", "uint16", "uint32", "uint64", "uintptr", "any"
        ]
        spec.constants = ["true", "false", "nil", "iota"]
        spec.stringDelimiters = ["\"", "'"]
        // Raw string literals, which are exactly the ones that span lines.
        spec.multilineStringDelimiters = [Array("`")]
        spec.declarationKeywords = ["type", "package"]
        spec.capitalisedIsType = true
        return spec
    }

    static var rustSpec: Spec {
        var spec = Spec()
        cStyleComments(&spec, nested: true)
        spec.keywords = [
            "as", "async", "await", "break", "const", "continue", "crate", "dyn",
            "else", "enum", "extern", "fn", "for", "if", "impl", "in", "let",
            "loop", "match", "mod", "move", "mut", "pub", "ref", "return",
            "static", "struct", "super", "trait", "type", "unsafe", "use",
            "where", "while", "union", "macro_rules"
        ]
        spec.types = [
            "i8", "i16", "i32", "i64", "i128", "isize", "u8", "u16", "u32", "u64",
            "u128", "usize", "f32", "f64", "bool", "char", "str"
        ]
        spec.constants = ["true", "false", "None", "Some", "Ok", "Err", "self", "Self"]
        spec.stringDelimiters = ["\"", "'"]
        spec.directiveSigils = ["#"]
        spec.declarationKeywords = ["struct", "enum", "trait", "union", "impl", "mod"]
        spec.capitalisedIsType = true
        return spec
    }

    static var pythonSpec: Spec {
        var spec = Spec()
        spec.lineComments = [Array("#")]
        spec.keywords = [
            "and", "as", "assert", "async", "await", "break", "class", "continue",
            "def", "del", "elif", "else", "except", "finally", "for", "from",
            "global", "if", "import", "in", "is", "lambda", "nonlocal", "not",
            "or", "pass", "raise", "return", "try", "while", "with", "yield",
            "match", "case"
        ]
        spec.types = [
            "int", "float", "str", "bool", "bytes", "list", "dict", "set",
            "tuple", "complex", "frozenset", "object", "type"
        ]
        spec.constants = ["True", "False", "None", "self", "cls", "NotImplemented", "Ellipsis"]
        spec.stringDelimiters = ["\"", "'"]
        // Longest first: `"""` has to be tried before `"` or every docstring
        // would open and close on its own first character.
        spec.multilineStringDelimiters = [Array("\"\"\""), Array("'''")]
        spec.directiveSigils = ["@"]
        spec.declarationKeywords = ["class"]
        spec.capitalisedIsType = true
        return spec
    }

    static var rubySpec: Spec {
        var spec = Spec()
        spec.lineComments = [Array("#")]
        spec.keywords = [
            "alias", "and", "begin", "break", "case", "class", "def", "defined?",
            "do", "else", "elsif", "end", "ensure", "for", "if", "in", "module",
            "next", "not", "or", "redo", "rescue", "retry", "return", "then",
            "undef", "unless", "until", "when", "while", "yield", "require",
            "require_relative", "include", "extend", "attr_accessor",
            "attr_reader", "attr_writer", "lambda", "proc", "raise", "new",
            "private", "protected", "public"
        ]
        spec.constants = ["true", "false", "nil", "self", "super", "__FILE__", "__dir__"]
        spec.stringDelimiters = ["\"", "'"]
        // `empty?`, `save!`, `defined?` — the trailing character is part of the
        // method name in Ruby and nowhere else here.
        spec.extraIdentifierCharacters = ["?", "!"]
        spec.declarationKeywords = ["class", "module"]
        spec.capitalisedIsType = true
        return spec
    }

    static var shellSpec: Spec {
        var spec = Spec()
        spec.lineComments = [Array("#")]
        spec.keywords = [
            "if", "then", "else", "elif", "fi", "case", "esac", "for", "while",
            "until", "do", "done", "function", "in", "select", "time", "return",
            "break", "continue", "local", "export", "readonly", "declare",
            "typeset", "source", "alias", "unalias", "unset", "shift", "exit",
            "trap", "set", "eval", "exec", "echo", "printf", "read", "cd", "test"
        ]
        spec.constants = ["true", "false"]
        spec.stringDelimiters = ["\"", "'"]
        // Shell constants SHOUT (`$HOME`, `PATH=`), so capitalisation says
        // nothing about types here — and shell has no types to speak of.
        spec.capitalisedIsType = false
        return spec
    }

    static var sqlSpec: Spec {
        var spec = Spec()
        spec.lineComments = [Array("--")]
        spec.blockCommentOpen = Array("/*")
        spec.blockCommentClose = Array("*/")
        spec.keywords = [
            "select", "from", "where", "insert", "into", "values", "update",
            "set", "delete", "create", "alter", "drop", "table", "view", "index",
            "join", "inner", "left", "right", "full", "outer", "cross", "on",
            "group", "by", "order", "having", "limit", "offset", "as", "and",
            "or", "not", "null", "is", "in", "between", "like", "distinct",
            "union", "all", "exists", "case", "when", "then", "else", "end",
            "primary", "key", "foreign", "references", "default", "constraint",
            "unique", "check", "with", "returning", "asc", "desc", "begin",
            "commit", "rollback", "transaction", "if", "cascade"
        ]
        spec.types = [
            "int", "integer", "bigint", "smallint", "decimal", "numeric", "real",
            "float", "double", "char", "varchar", "text", "date", "time",
            "timestamp", "boolean", "blob", "json", "jsonb", "uuid", "serial"
        ]
        spec.constants = ["true", "false", "null"]
        // `SELECT` and `select` are the same word; so is `Varchar`.
        spec.caseInsensitiveKeywords = true
        spec.stringDelimiters = ["'", "\""]
        return spec
    }

    static var jsonSpec: Spec {
        var spec = Spec()
        // Strict JSON has no comments, but the files people actually keep in a
        // repo — tsconfig, VS Code settings — are JSONC, and a `//` line shows
        // up as a comment rather than as a mess of broken strings.
        cStyleComments(&spec)
        spec.constants = ["true", "false", "null"]
        spec.stringDelimiters = ["\""]
        return spec
    }

    static var yamlSpec: Spec {
        var spec = Spec()
        spec.lineComments = [Array("#")]
        spec.constants = ["true", "false", "null", "yes", "no", "on", "off", "~"]
        spec.stringDelimiters = ["\"", "'"]
        return spec
    }

    static var cssSpec: Spec {
        var spec = Spec()
        spec.blockCommentOpen = Array("/*")
        spec.blockCommentClose = Array("*/")
        // SCSS and LESS both take `//`, and plain CSS files never contain one
        // outside a URL — which is inside a string by then.
        spec.lineComments = [Array("//")]
        spec.keywords = [
            "important", "from", "to", "and", "not", "only", "screen", "print",
            "inherit", "initial", "unset", "revert", "auto", "none"
        ]
        spec.stringDelimiters = ["\"", "'"]
        // `@media`, `@import`, `@keyframes`.
        spec.directiveSigils = ["@"]
        return spec
    }
}
