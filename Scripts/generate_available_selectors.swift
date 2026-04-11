import Foundation

struct SelectorList: Decodable {
    let selectors: [SelectorItem]
}

struct SelectorItem: Decodable {
    let selector: String
    let scope: String
    let summary: String
}

enum GenerateError: Error, CustomStringConvertible {
    case invalidArguments
    case emptySelector
    case emptyScope(selector: String)
    case emptySummary(selector: String)
    case invalidScope(selector: String, scope: String)

    var description: String {
        switch self {
        case .invalidArguments:
            return "usage: generate_available_selectors.swift <input.json> <output.html>"
        case .emptySelector:
            return "selector must not be empty."
        case .emptyScope(let selector):
            return "scope must not be empty. selector=\(selector)"
        case .emptySummary(let selector):
            return "summary must not be empty. selector=\(selector)"
        case .invalidScope(let selector, let scope):
            return "invalid scope. selector=\(selector), scope=\(scope)"
        }
    }
}

let validScopes: Set<String> = [
    "Application",
    "Document",
    "ViewController",
    "TextView"
]

func htmlEscaped(_ string: String) -> String {
    string
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&#39;")
}

func validate(_ items: [SelectorItem]) throws {
    for item in items {
        if item.selector.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw GenerateError.emptySelector
        }

        if item.scope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw GenerateError.emptyScope(selector: item.selector)
        }

        if item.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw GenerateError.emptySummary(selector: item.selector)
        }

        if !validScopes.contains(item.scope) {
            throw GenerateError.invalidScope(selector: item.selector, scope: item.scope)
        }
    }
}

func makeHTML(from items: [SelectorItem]) -> String {
    let grouped = Dictionary(grouping: items, by: \.scope)

    let orderedScopes = ["Application", "Document", "ViewController", "TextView"]

    var body = ""
    body += "<main class=\"contents\">\n"
    body += "<h1 id=\"available_selectors\">Available Selectors</h1>\n"
    body += "<p class=\"muted\">セレクターはスコープによりグループ分けされています。左のカラムはセレクター名、右のカラムは簡単な説明となっています。</p>\n"
    body += "<nav class=\"toc\" aria-label=\"contents\">\n"
    body += "<h2>Contents</h2>\n"
    body += "<ul>\n"

    for scope in orderedScopes where grouped[scope] != nil {
        let anchor = scope.lowercased()
        body += "<li><a href=\"#\(anchor)\">\(htmlEscaped(scope))</a></li>\n"
    }

    body += "</ul>\n"
    body += "</nav>\n"

    for scope in orderedScopes {
        guard let scopeItems = grouped[scope] else { continue }

        let sortedItems = scopeItems.sorted {
            $0.selector.localizedCaseInsensitiveCompare($1.selector) == .orderedAscending
        }

        let anchor = scope.lowercased()
        body += "<h2 id=\"\(anchor)\">\(htmlEscaped(scope))</h2>\n"
        body += "<table class=\"selector-table\">\n"
        body += "<thead><tr><th class=\"sel\">Selector</th><th>Description</th></tr></thead>\n"
        body += "<tbody>\n"

        for item in sortedItems {
            body += "<tr>"
            body += "<td class=\"sel\"><code>\(htmlEscaped(item.selector))</code></td>"
            body += "<td>\(htmlEscaped(item.summary))</td>"
            body += "</tr>\n"
        }

        body += "</tbody>\n"
        body += "</table>\n"
    }

    body += "</main>\n"

    return """
    <!doctype html>
    <html lang="ja">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Available Selectors</title>
    <link rel="stylesheet" href="help.css">
    </head>
    <body>
    \(body)</body>
    </html>
    """
}

func ensureParentDirectory(for outputURL: URL) throws {
    let directoryURL = outputURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
}

do {
    let arguments = CommandLine.arguments
    guard arguments.count == 3 else {
        throw GenerateError.invalidArguments
    }

    let inputURL = URL(fileURLWithPath: arguments[1])
    let outputURL = URL(fileURLWithPath: arguments[2])

    let data = try Data(contentsOf: inputURL)
    let decoded = try JSONDecoder().decode(SelectorList.self, from: data)

    try validate(decoded.selectors)

    let html = makeHTML(from: decoded.selectors)

    try ensureParentDirectory(for: outputURL)
    try html.write(to: outputURL, atomically: true, encoding: .utf8)
}
catch let error as GenerateError {
    fputs("error: \(error.description)\n", stderr)
    exit(1)
}
catch {
    fputs("error: \(error)\n", stderr)
    exit(1)
}