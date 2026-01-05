import Foundation
import OpenMDict

// MARK: - Terminal Colors

enum ANSIColor: String {
    case reset = "\u{001B}[0m"
    case red = "\u{001B}[31m"
    case green = "\u{001B}[32m"
    case yellow = "\u{001B}[33m"
    case blue = "\u{001B}[34m"
    case magenta = "\u{001B}[35m"
    case cyan = "\u{001B}[36m"
    case bold = "\u{001B}[1m"
    case dim = "\u{001B}[2m"
}

func colored(_ text: String, _ color: ANSIColor) -> String {
    "\(color.rawValue)\(text)\(ANSIColor.reset.rawValue)"
}

// MARK: - Main

func printUsage() {
    print("""
    
    \(colored("OpenMDict", .bold)) - MDict MDX/MDD Parser
    
    \(colored("Usage:", .yellow))
        openmdict <mdx_file>                        Show dictionary info
        openmdict <mdx_file> lookup <word>          Look up a word
        openmdict <mdx_file> search <prefix>        Search by prefix
        openmdict <mdx_file> list [count]           List first N entries
        openmdict <mdx_file> resources [count]      List resources from MDD
        openmdict <mdx_file> resource <path>        Get a specific resource
    
    \(colored("Examples:", .yellow))
        openmdict MyDict.mdx
        openmdict MyDict.mdx lookup hello
        openmdict MyDict.mdx search happ
        openmdict MyDict.mdx list 20
        openmdict MyDict.mdx resources 10
        openmdict MyDict.mdx resource mydict.css
    
    """)
}

func main() {
    let args = CommandLine.arguments
    
    guard args.count >= 2 else {
        printUsage()
        exit(1)
    }
    
    let mdxPath = args[1]
    
    guard FileManager.default.fileExists(atPath: mdxPath) else {
        print(colored("Error: File not found: \(mdxPath)", .red))
        exit(1)
    }
    
    print()
    print(colored("📖 Opening:", .cyan), mdxPath)
    print()
    
    let startTime = CFAbsoluteTimeGetCurrent()
    
    do {
        let dict = try MDictReader(path: mdxPath)
        let loadTime = CFAbsoluteTimeGetCurrent() - startTime
        
        // Dictionary info
        print(colored("Dictionary Info:", .bold))
        print("  Title:          ", dict.metadata.title)
        print("  Entries:        ", colored("\(dict.entryCount)", .green))
        print("  Format:         ", dict.metadata.format)
        print("  Encoding:       ", dict.metadata.encoding)
        print("  Engine Version: ", dict.metadata.engineVersion)
        print("  Encrypted:      ", dict.metadata.isEncrypted ? colored("Yes", .yellow) : colored("No", .green))
        print("  Case Sensitive: ", dict.metadata.isCaseSensitive ? "Yes" : "No")
        print()
        
        // Resource info
        print(colored("Resource Info:", .bold))
        if dict.resourceCount > 0 {
            print("  MDD Resources:  ", colored("\(dict.resourceCount)", .green))
            
            // Show resource types summary
            let paths = dict.allResourcePaths
            let extensions = Dictionary(grouping: paths) { path in
                (path as NSString).pathExtension.lowercased()
            }.mapValues { $0.count }
            
            let summary = extensions.sorted { $0.value > $1.value }
                .prefix(5)
                .map { "\($0.key.isEmpty ? "other" : $0.key): \($0.value)" }
                .joined(separator: ", ")
            print("  Types:          ", colored(summary, .dim))
        } else {
            print("  MDD Resources:  ", colored("None (no .mdd file found)", .yellow))
        }
        print()
        
        print("  Load Time:      ", colored(String(format: "%.2f ms", loadTime * 1000), .yellow))
        print()
        
        if args.count >= 3 {
            let command = args[2].lowercased()
            
            switch command {
            case "lookup":
                guard args.count >= 4 else {
                    print(colored("Error: Missing word for lookup", .red))
                    exit(1)
                }
                performLookup(dict: dict, word: args[3])
                
            case "search":
                guard args.count >= 4 else {
                    print(colored("Error: Missing prefix for search", .red))
                    exit(1)
                }
                performSearch(dict: dict, prefix: args[3])
                
            case "list":
                let count = args.count >= 4 ? Int(args[3]) ?? 20 : 20
                listEntries(dict: dict, count: count)
                
            case "resources":
                let count = args.count >= 4 ? Int(args[3]) ?? 20 : 20
                listResources(dict: dict, count: count)
                
            case "resource":
                guard args.count >= 4 else {
                    print(colored("Error: Missing resource path", .red))
                    exit(1)
                }
                getResource(dict: dict, path: args[3])
                
            default:
                print(colored("Unknown command: \(command)", .red))
                printUsage()
                exit(1)
            }
        } else {
            // Default: show sample entries
            print(colored("First 10 entries:", .bold))
            for (i, entry) in dict.allKeys.prefix(10).enumerated() {
                print("  \(i + 1). \(entry)")
            }
            print()
            print(colored("Tip:", .yellow), "Use 'lookup <word>' to look up a word")
        }
        
    } catch {
        print(colored("Error: \(error)", .red))
        exit(1)
    }
}

// MARK: - Commands

func performLookup(dict: MDictReader, word: String) {
    print(colored("🔍 Looking up:", .cyan), word)
    print()
    
    let startTime = CFAbsoluteTimeGetCurrent()
    
    if let entry = dict.lookup(word) {
        let lookupTime = CFAbsoluteTimeGetCurrent() - startTime
        let content = entry.article.html
        
        // Extract referenced resources from HTML
        let resourceRefs = extractResourceRefs(from: content)
        
        let displayContent = content.count > 2000 
            ? String(content.prefix(2000)) + "\n... [truncated, \(content.count) chars total]"
            : content
        
        print(colored("Result:", .green))
        print(String(repeating: "─", count: 60))
        print(displayContent)
        print(String(repeating: "─", count: 60))
        print()
        
        // Show navigation
        print(colored("Navigation:", .bold))
        if entry.index > 0, let prev = dict[entry.index - 1] {
            print("  ← Previous: ", colored(prev.key, .cyan))
        }
        if let next = dict[entry.index + 1] {
            print("  → Next:     ", colored(next.key, .cyan))
        }
        print()
        
        // Show referenced resources by type
        if !resourceRefs.isEmpty {
            showResourceRefs(refs: resourceRefs, dict: dict)
        }
        
        print(colored("✓", .green), "Found in", colored(String(format: "%.2f ms", lookupTime * 1000), .yellow))
    } else {
        print(colored("✗ Not found:", .red), word)
        
        let suggestions = dict.suggestions(for: word, limit: 5)
        if !suggestions.isEmpty {
            print()
            print(colored("Did you mean:", .yellow))
            for s in suggestions { print("  • \(s)") }
        }
    }
    print()
}

func performSearch(dict: MDictReader, prefix: String) {
    print(colored("🔎 Searching prefix:", .cyan), prefix)
    print()
    
    let startTime = CFAbsoluteTimeGetCurrent()
    let results = dict.search(prefix: prefix, limit: 20)
    let searchTime = CFAbsoluteTimeGetCurrent() - startTime
    
    if results.isEmpty {
        print(colored("No matches found", .yellow))
    } else {
        print(colored("Matches (\(results.count)):", .green))
        for (i, result) in results.enumerated() {
            print("  \(i + 1). \(result)")
        }
    }
    
    print()
    print(colored("✓", .green), "Search completed in", colored(String(format: "%.2f ms", searchTime * 1000), .yellow))
    print()
}

func listEntries(dict: MDictReader, count: Int) {
    print(colored("📝 First \(count) entries:", .bold))
    print()
    
    for (i, entry) in dict.allKeys.prefix(count).enumerated() {
        print("  \(String(format: "%4d", i + 1)). \(entry)")
    }
    print()
}

func listResources(dict: MDictReader, count: Int) {
    print(colored("📦 Resources:", .bold))
    print()
    
    let paths = dict.allResourcePaths
    
    if paths.isEmpty {
        print(colored("  No MDD resources found", .yellow))
        print()
        return
    }
    
    for (i, path) in paths.prefix(count).enumerated() {
        let ext = (path as NSString).pathExtension.lowercased()
        let icon: String
        switch ext {
        case "css": icon = "🎨"
        case "js": icon = "📜"
        case "png", "jpg", "jpeg", "gif", "svg": icon = "🖼️"
        case "mp3", "wav", "ogg", "spx": icon = "🔊"
        case "ttf", "otf", "woff", "woff2": icon = "🔤"
        default: icon = "📄"
        }
        print("  \(String(format: "%4d", i + 1)). \(icon) \(path)")
    }
    
    if paths.count > count {
        print()
        print(colored("  ... and \(paths.count - count) more resources", .dim))
    }
    print()
}

func getResource(dict: MDictReader, path: String) {
    print(colored("📦 Resource:", .cyan), path)
    print()
    
    guard let data = dict.resource(for: path) else {
        print(colored("✗ Resource not found:", .red), path)
        print()
        
        // Try to find similar resources
        let similar = dict.allResourcePaths.filter { 
            $0.lowercased().contains(path.lowercased()) 
        }.prefix(5)
        
        if !similar.isEmpty {
            print(colored("Similar resources:", .yellow))
            for s in similar { print("  • \(s)") }
        }
        print()
        return
    }
    
    let ext = (path as NSString).pathExtension.lowercased()
    let mime = ResourceProvider.mimeType(for: path)
    
    print(colored("Info:", .bold))
    print("  Size:      ", colored("\(data.count) bytes", .green))
    print("  MIME Type: ", mime)
    print()
    
    // Show content preview for text types
    let textTypes = ["css", "js", "html", "htm", "xml", "json", "txt", "svg"]
    if textTypes.contains(ext) {
        if let content = String(data: data, encoding: .utf8) {
            let preview = content.count > 1000 
                ? String(content.prefix(1000)) + "\n... [truncated]"
                : content
            
            print(colored("Content Preview:", .bold))
            print(String(repeating: "─", count: 60))
            print(preview)
            print(String(repeating: "─", count: 60))
        }
    } else {
        // Show hex dump for binary
        print(colored("Hex Preview (first 64 bytes):", .bold))
        let hexBytes = data.prefix(64).map { String(format: "%02X", $0) }
        for row in stride(from: 0, to: hexBytes.count, by: 16) {
            let slice = hexBytes[row..<min(row + 16, hexBytes.count)]
            print("  \(slice.joined(separator: " "))")
        }
    }
    print()
}

// MARK: - Helpers

struct ResourceRef {
    enum RefType {
        case localResource    // CSS, images in MDD or external
        case audio            // sound:// protocol
        case entryLink        // entry:// cross-reference
        case webLink          // website links like /definition/
    }
    
    let path: String
    let type: RefType
}

func extractResourceRefs(from html: String) -> [ResourceRef] {
    var refs: [String: ResourceRef] = [:]
    
    // Match href="..." and src="..."
    let patterns = [
        #"href\s*=\s*"([^"]+)""#,
        #"src\s*=\s*"([^"]+)""#,
        #"url\s*\(\s*'?([^')]+)'?\s*\)"#
    ]
    
    for pattern in patterns {
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            let range = NSRange(html.startIndex..., in: html)
            let matches = regex.matches(in: html, range: range)
            
            for match in matches {
                if let refRange = Range(match.range(at: 1), in: html) {
                    let path = String(html[refRange])
                    
                    // Classify the reference
                    let ref: ResourceRef?
                    
                    if path.hasPrefix("http://") || path.hasPrefix("https://") {
                        // Skip external URLs
                        ref = nil
                    } else if path.hasPrefix("#") {
                        // Skip anchors
                        ref = nil
                    } else if path.hasPrefix("entry://") {
                        ref = ResourceRef(path: path, type: .entryLink)
                    } else if path.hasPrefix("sound://") {
                        // Extract path after sound://
                        let audioPath = String(path.dropFirst("sound://".count))
                        ref = ResourceRef(path: audioPath, type: .audio)
                    } else if path.hasPrefix("/definition/") || 
                              path.hasPrefix("/pronunciation/") ||
                              path.hasPrefix("/mywordlist") ||
                              path.hasPrefix("/wordlist/") ||
                              path.hasPrefix("/topic/") {
                        // Website links, not local resources
                        ref = ResourceRef(path: path, type: .webLink)
                    } else if path.hasSuffix(".css") || path.hasSuffix(".js") ||
                              path.hasSuffix(".png") || path.hasSuffix(".jpg") ||
                              path.hasSuffix(".gif") || path.hasSuffix(".svg") ||
                              path.hasSuffix(".ttf") || path.hasSuffix(".woff") {
                        ref = ResourceRef(path: path, type: .localResource)
                    } else {
                        // Unknown - could be resource or link
                        ref = ResourceRef(path: path, type: .webLink)
                    }
                    
                    if let ref = ref, refs[path] == nil {
                        refs[path] = ref
                    }
                }
            }
        }
    }
    
    return Array(refs.values).sorted { $0.path < $1.path }
}

func showResourceRefs(refs: [ResourceRef], dict: MDictReader) {
    let grouped = Dictionary(grouping: refs) { $0.type }
    
    // Local resources (CSS, images)
    if let local = grouped[.localResource], !local.isEmpty {
        print(colored("Local Resources:", .bold))
        for ref in local.prefix(5) {
            let exists = dict.hasResource(ref.path)
            let status = exists ? colored("✓", .green) : colored("✗", .yellow)
            print("  \(status) \(ref.path)")
        }
        if local.count > 5 {
            print("  ... and \(local.count - 5) more")
        }
        print()
    }
    
    // Audio files
    if let audio = grouped[.audio], !audio.isEmpty {
        print(colored("Audio Files:", .bold))
        for ref in audio.prefix(5) {
            let exists = dict.hasResource(ref.path)
            let status = exists ? colored("✓", .green) : colored("✗", .yellow)
            print("  \(status) 🔊 \(ref.path)")
        }
        if audio.count > 5 {
            print("  ... and \(audio.count - 5) more")
        }
        print()
    }
    
    // Entry cross-references
    if let entries = grouped[.entryLink], !entries.isEmpty {
        print(colored("Cross-references:", .bold))
        for ref in entries.prefix(5) {
            let entryName = ref.path.replacingOccurrences(of: "entry://", with: "")
            print("  → \(entryName)")
        }
        if entries.count > 5 {
            print("  ... and \(entries.count - 5) more")
        }
        print()
    }
}

main()
