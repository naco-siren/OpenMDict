import Testing

/// The suites whose readers depend on `MDictSidecarCache`'s process-wide
/// state — the directory sidecars and folded-key indexes are saved to and
/// read from, and the write mode — run one at a time. Suites run in
/// parallel otherwise, and a reader one suite opens while another has set
/// its own directory would read the files saved there (the fallbacks
/// fixture's folded index, say) or save its own into it.
@Suite(.serialized)
enum SidecarCacheSuites {}
