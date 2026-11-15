import Foundation

/// Line-addressed edits on a whole-file buffer.
///
/// The compare view edits by line number, because a line number is what a
/// diff row is. That arithmetic lives here rather than inside the view for
/// one reason: an off-by-one on a line index is a silent corruption of
/// somebody's file — it writes the wrong line and looks like it worked —
/// and this way it can be tested.
///
/// Every operation is total. An out-of-range line number returns the buffer
/// untouched rather than trapping: the numbers come from a diff that is
/// recomputed asynchronously, so "the row moved under the edit" is a state
/// the caller can reach without doing anything wrong.
enum TextBufferEdits {

    /// Splits the way `LineDiff.split` does, so line numbers mean the same
    /// thing here as they do in the alignment.
    static func lines(of text: String) -> [String] {
        text.components(separatedBy: "\n")
    }

    static func line(_ number: Int, in text: String) -> String {
        let all = lines(of: text)
        guard number >= 1, number <= all.count else { return "" }
        return all[number - 1]
    }

    /// Replaces line `number`.
    ///
    /// Text carrying newlines becomes the lines it contains rather than
    /// being flattened into one: pasting three lines into a row is a
    /// reasonable way to add three lines, and joining them would quietly
    /// mangle the paste.
    static func setting(line number: Int, to replacement: String, in text: String) -> String {
        var all = lines(of: text)
        guard number >= 1, number <= all.count else { return text }
        all.replaceSubrange((number - 1)...(number - 1), with: lines(of: replacement))
        return all.joined(separator: "\n")
    }

    /// Inserts an empty line, which becomes line `number`.
    static func insertingEmptyLine(at number: Int, in text: String) -> String {
        var all = lines(of: text)
        let index = min(max(number - 1, 0), all.count)
        all.insert("", at: index)
        return all.joined(separator: "\n")
    }

    static func removing(line number: Int, in text: String) -> String {
        var all = lines(of: text)
        guard number >= 1, number <= all.count else { return text }
        all.remove(at: number - 1)
        return all.joined(separator: "\n")
    }

    /// A run of lines the user retyped as one piece of text — one block of a
    /// diff, edited in the compare window.
    ///
    /// The text is free to be any number of lines, including none of the ones
    /// it replaces and including more than it replaces: a block editor is
    /// where lines are added and removed, and neither is expressible one line
    /// at a time.
    struct Block: Equatable {
        /// 1-based first line the block covers.
        let start: Int
        /// How many lines it covers. Zero inserts `text` before `start`
        /// without replacing anything — a block that exists only on the HEAD
        /// side, being typed back into the working file.
        let count: Int
        /// What those lines become. Empty means they go: see `replacing`.
        let text: String
        /// Unless this says otherwise. A block taken from the other side of a
        /// compare can *be* a single blank line, and an empty string is what
        /// that looks like once its one line is joined — indistinguishable,
        /// without this, from the empty string that means "take them out".
        var emptyIsOneBlankLine: Bool = false
    }

    /// Replaces the lines a block covers with the lines of its text.
    ///
    /// An empty text removes them outright rather than leaving one blank line
    /// behind. Splitting `""` yields one empty line, which is the arithmetic
    /// answer and the wrong one: "delete everything in this block" has to be
    /// expressible, and the user who clears a block means the lines to be
    /// gone, not blanked. The cost is that a block cannot be edited *into* a
    /// single blank line — a thing nobody has ever wanted a block to become.
    static func replacing(_ block: Block, in text: String) -> String {
        var all = lines(of: text)
        let first = min(max(block.start - 1, 0), all.count)
        let last = min(first + max(block.count, 0), all.count)
        let replacement = block.text.isEmpty && !block.emptyIsOneBlankLine
            ? []
            : lines(of: block.text)
        all.replaceSubrange(first..<last, with: replacement)
        return all.joined(separator: "\n")
    }

    /// What Backspace means inside a block editor, given the block's text and
    /// where the caret sits in it.
    ///
    /// A block has no line above its first one that the editor can reach —
    /// that line belongs to the block next door, which is a separate draft —
    /// so the key runs out of room exactly where an ordinary editor would
    /// join two lines. This is what it does instead.
    enum BlockBackspace: Equatable {
        /// An ordinary backspace; the text view should have it.
        case passThrough
        /// The block holds nothing at all: it goes, and the caret carries on
        /// in the block above.
        case leaveBlock
        /// The caret is at the top of the block, on a line that has been
        /// emptied. Take that line out and pull the rest of the block up —
        /// the only side the join can be made from here.
        case dropFirstLine
    }

    /// `selection` is the text view's own, in UTF-16 units.
    static func backspace(in text: String, selection: NSRange) -> BlockBackspace {
        if text.isEmpty { return .leaveBlock }
        // A selection, or a caret anywhere else, has something behind it to
        // delete and needs nothing from us.
        guard selection.length == 0, selection.location == 0 else { return .passThrough }
        // A leading newline is an empty first line. With anything else there
        // the caret is in front of real text, and dropping the line would
        // throw away characters the user never deleted.
        return text.hasPrefix("\n") ? .dropFirstLine : .passThrough
    }

    /// Applies a whole batch of blocks at once — what the compare view's Save
    /// does with the drafts it has been holding.
    ///
    /// A batch rather than one call per block because every block's line
    /// numbers were read off the *same* text: line 12 means the twelfth line
    /// of the buffer the user was looking at, not of whatever the previous
    /// block left behind. Applied from the bottom up, which is what keeps
    /// that true — a block that grows or shrinks moves only the lines below
    /// it, and those have already been dealt with.
    static func applying(blocks: [Block], to text: String) -> String {
        var out = text
        for block in blocks.sorted(by: { $0.start > $1.start }) {
            out = replacing(block, in: out)
        }
        return out
    }
}
