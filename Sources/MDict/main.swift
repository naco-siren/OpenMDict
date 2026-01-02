import Foundation

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
}

func colored(_ text: String, _ color: ANSIColor) -> String {
    "\(color.rawValue)\(text)\(ANSIColor.reset.rawValue)"
}

// MARK: - Main

func printUsage() {
    print("""
    
    \(colored("MDictPOC", .bold)) - MDict MDX/MDD Parser Proof of Concept
    
    \(colored("Usage:", .yellow))
        mdict-poc <mdx_file>                    Show dictionary info
        mdict-poc <mdx_file> lookup <word>      Look up a word
        mdict-poc <mdx_file> search <prefix>    Search by prefix
        mdict-poc <mdx_file> list [count]       List first N entries
    
    \(colored("Examples:", .yellow))
        mdict-poc MyDict.mdx
        mdict-poc MyDict.mdx lookup hello
        mdict-poc MyDict.mdx search happ
        mdict-poc MyDict.mdx list 20
    
    """)
}

func formatFileSize(_ bytes: UInt64) -> String {
    let units = ["B", "KB", "MB", "GB"]
    var size = Double(bytes)
    var unitIndex = 0
    
    while size >= 1024 && unitIndex < units.count - 1 {
        size /= 1024
        unitIndex += 1
    }
    
    return String(format: "%.1f %@", size, units[unitIndex])
}

func main() {
    let args = CommandLine.arguments
    
    guard args.count >= 2 else {
        printUsage()
        exit(1)
    }
    
    let mdxPath = args[1]
    
    // Check file exists
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
        
        // Print header info
        print(colored("Dictionary Info:", .bold))
        print("  Title:          ", dict.header.title)
        print("  Entries:        ", colored("\(dict.entryCount)", .green))
        print("  Format:         ", dict.header.format)
        print("  Encoding:       ", dict.header.encoding)
        print("  Engine Version: ", dict.header.generatedByEngineVersion)
        print("  Encrypted:      ", encryptedDescription(dict.header.encrypted))
        print("  Case Sensitive: ", dict.header.keyCaseSensitive ? "Yes" : "No")
        print("  Load Time:      ", colored(String(format: "%.2f ms", loadTime * 1000), .yellow))
        print()
        
        // Handle commands
        if args.count >= 3 {
            let command = args[2].lowercased()
            
            switch command {
            case "lookup":
                guard args.count >= 4 else {
                    print(colored("Error: Missing word for lookup", .red))
                    exit(1)
                }
                let word = args[3]
                try performLookup(dict: dict, word: word)
                
            case "search":
                guard args.count >= 4 else {
                    print(colored("Error: Missing prefix for search", .red))
                    exit(1)
                }
                let prefix = args[3]
                performSearch(dict: dict, prefix: prefix)
                
            case "list":
                let count = args.count >= 4 ? Int(args[3]) ?? 20 : 20
                listEntries(dict: dict, count: count)
                
            default:
                print(colored("Unknown command: \(command)", .red))
                printUsage()
                exit(1)
            }
        } else {
            // Default: show first 10 entries
            print(colored("First 10 entries:", .bold))
            for (i, entry) in dict.entries.prefix(10).enumerated() {
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

func encryptedDescription(_ value: Int) -> String {
    switch value {
    case 0: return colored("None", .green)
    case 1: return colored("DRM (Salsa20) - Not Supported", .red)
    case 2: return colored("Index Only (auto-decryptable)", .yellow)
    case 3: return colored("DRM + Index - Not Supported", .red)
    default: return "Unknown (\(value))"
    }
}

func performLookup(dict: MDictReader, word: String) throws {
    print(colored("🔍 Looking up:", .cyan), word)
    print()
    
    let startTime = CFAbsoluteTimeGetCurrent()
    
    if let content = try dict.lookup(word) {
        let lookupTime = CFAbsoluteTimeGetCurrent() - startTime
        
        // Truncate long content for display
        let displayContent: String
        if content.count > 2000 {
            displayContent = String(content.prefix(2000)) + "\n... [truncated, \(content.count) chars total]"
        } else {
            displayContent = content
        }
        
        print(colored("Result:", .green))
        print("─" * 60)
        print(displayContent)
        print("─" * 60)
        print()
        print(colored("✓", .green), "Found in", colored(String(format: "%.2f ms", lookupTime * 1000), .yellow))
    } else {
        print(colored("✗ Not found:", .red), word)
        
        // Suggest similar words
        let suggestions = dict.search(prefix: String(word.prefix(3)), limit: 5)
        if !suggestions.isEmpty {
            print()
            print(colored("Did you mean:", .yellow))
            for s in suggestions {
                print("  • \(s)")
            }
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
    
    for (i, entry) in dict.entries.prefix(count).enumerated() {
        print("  \(String(format: "%4d", i + 1)). \(entry)")
    }
    print()
}

// Helper for repeating strings
extension String {
    static func * (left: String, right: Int) -> String {
        String(repeating: left, count: right)
    }
}

// Run
main()
