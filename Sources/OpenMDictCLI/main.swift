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
        
        print(colored("Dictionary Info:", .bold))
        print("  Title:          ", dict.info.title)
        print("  Entries:        ", colored("\(dict.info.entryCount)", .green))
        print("  Format:         ", dict.info.format)
        print("  Encoding:       ", dict.info.encoding)
        print("  Engine Version: ", dict.info.engineVersion)
        print("  Encrypted:      ", dict.info.isEncrypted ? colored("Yes", .yellow) : colored("No", .green))
        print("  Case Sensitive: ", dict.info.isCaseSensitive ? "Yes" : "No")
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
                
            default:
                print(colored("Unknown command: \(command)", .red))
                printUsage()
                exit(1)
            }
        } else {
            print(colored("First 10 entries:", .bold))
            for (i, entry) in dict.allKeywords.prefix(10).enumerated() {
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

func performLookup(dict: MDictReader, word: String) {
    print(colored("🔍 Looking up:", .cyan), word)
    print()
    
    let startTime = CFAbsoluteTimeGetCurrent()
    
    if let entry = dict.lookup(word) {
        let lookupTime = CFAbsoluteTimeGetCurrent() - startTime
        let content = entry.definition
        let displayContent = content.count > 2000 
            ? String(content.prefix(2000)) + "\n... [truncated, \(content.count) chars total]"
            : content
        
        print(colored("Result:", .green))
        print(String(repeating: "─", count: 60))
        print(displayContent)
        print(String(repeating: "─", count: 60))
        print()
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
    
    for (i, entry) in dict.allKeywords.prefix(count).enumerated() {
        print("  \(String(format: "%4d", i + 1)). \(entry)")
    }
    print()
}

main()
