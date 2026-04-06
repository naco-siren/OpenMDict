//
//  ArticleHTMLRenderer.swift
//  OpenMDict-iOS
//
//  Shared HTML rendering for article content
//  Used by both ArticleCell (regular) and ArticleViewController (compact)
//

import UIKit

/// Generates styled HTML for article display in WKWebView
enum ArticleHTMLRenderer {
    
    // MARK: - Article Content
    
    /// Render dictionary article HTML with styling
    static func renderArticle(
        html: String,
        dictId: String,
        traitCollection: UITraitCollection
    ) -> String {
        let rewrittenHTML = HTMLResourceRewriter.rewriteResourcePaths(in: html, dictId: dictId)
        
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
            <style>
                body {
                    font-family: -apple-system, system-ui;
                    font-size: 15px;
                    line-height: 1.5;
                    margin: 12px;
                    padding: 0;
                    color: \(cssColor(.label, traitCollection));
                    background: transparent;
                }
                h2.h { font-size: 1.3em; margin: 0 0 8px 0; }
                .pos { color: \(cssColor(.secondaryLabel, traitCollection)); font-style: italic; }
                .def { display: block; margin: 8px 0; }
                .x { color: \(cssColor(.secondaryLabel, traitCollection)); display: block; margin: 4px 0 4px 16px; }
                .x::before { content: "• "; }
                .phon { color: \(cssColor(.systemBlue, traitCollection)); }
                .num { font-weight: bold; margin-right: 4px; }
                .collapse { display: block; margin-top: 12px; padding-top: 8px; border-top: 1px solid \(cssColor(.separator, traitCollection)); }
                .heading { font-weight: 600; display: block; margin-bottom: 4px; }
                a { color: \(cssColor(.link, traitCollection)); text-decoration: none; }
                img { max-width: 100%; height: auto; }
                
                /* Invisible positioning marks inside #_omdict_content */
                mark.find-hl { background: transparent; color: inherit; }
            </style>
            <script>
            function highlightKeyword(keyword) {
                var content = document.getElementById('_omdict_content');
                if (!content) content = document.body;

                // 1. Remove old invisible marks from content
                content.querySelectorAll('mark.find-hl').forEach(function(m) {
                    m.replaceWith(document.createTextNode(m.textContent));
                });
                content.normalize();

                // 2. Remove old find layer
                var oldFind = document.getElementById('_omdict_find');
                if (oldFind) oldFind.remove();

                if (!keyword || keyword.length < 1) return '[]';

                // 3. Find matches in content, wrap in invisible marks
                var escaped = keyword.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&');
                var regex = new RegExp('(' + escaped + ')', 'gi');
                var walker = document.createTreeWalker(content, NodeFilter.SHOW_TEXT, null);
                var nodes = [];
                while (walker.nextNode()) nodes.push(walker.currentNode);

                nodes.forEach(function(node) {
                    regex.lastIndex = 0;
                    if (regex.test(node.nodeValue)) {
                        regex.lastIndex = 0;
                        var span = document.createElement('span');
                        span.innerHTML = node.nodeValue.replace(regex, '<mark class="find-hl">$1</mark>');
                        node.parentNode.replaceChild(span, node);
                    }
                });

                var marks = content.querySelectorAll('mark.find-hl');
                if (marks.length === 0) return '[]';

                // 4. Create find layer (sibling of content — NOT filtered)
                var findLayer = document.createElement('div');
                findLayer.id = '_omdict_find';
                findLayer.style.cssText = 'position:absolute;top:0;left:0;width:100%;height:0;overflow:visible;pointer-events:none;z-index:9999';
                document.body.appendChild(findLayer);

                // 5. Dim overlay
                var dim = document.createElement('div');
                dim.textContent = '\\u200B';  // zero-width space defeats dict CSS "div:empty { display:none }"
                dim.style.cssText = 'position:fixed;top:0;left:0;right:0;bottom:0;background:rgba(0,0,0,0.3);font-size:0';
                findLayer.appendChild(dim);

                // 6. Positioned highlight spans with copied font
                var rects = [];
                marks.forEach(function(m) {
                    var r = m.getBoundingClientRect();
                    var cs = window.getComputedStyle(m);
                    var x = r.left + window.scrollX;
                    var y = r.top + window.scrollY;

                    var hl = document.createElement('span');
                    hl.textContent = m.textContent;
                    hl.style.cssText = 'position:absolute;background:#ffeb3b;color:#000;'
                        + 'white-space:pre;border-radius:3px;padding:0 2px;margin:-2px 0;'
                        + 'left:' + x + 'px;top:' + y + 'px;'
                        + 'font:' + cs.font + ';'
                        + 'line-height:' + cs.lineHeight + ';'
                        + 'letter-spacing:' + cs.letterSpacing + ';';
                    findLayer.appendChild(hl);

                    rects.push({x:x, y:y, w:r.width, h:r.height});
                });

                return JSON.stringify(rects);
            }
            </script>
        </head>
        <body><div id="_omdict_content">\(rewrittenHTML)</div></body>
        </html>
        """
    }
    
    // MARK: - Loading State
    
    /// Render loading/pending state HTML
    static func renderPending(
        word: String,
        traitCollection: UITraitCollection
    ) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <style>
                body {
                    font-family: -apple-system, system-ui;
                    display: flex;
                    flex-direction: column;
                    align-items: center;
                    justify-content: center;
                    height: 80vh;
                    margin: 0;
                    color: \(cssColor(.secondaryLabel, traitCollection));
                    background: transparent;
                }
                .spinner {
                    width: 24px;
                    height: 24px;
                    border: 3px solid \(cssColor(.separator, traitCollection));
                    border-top-color: \(cssColor(.systemBlue, traitCollection));
                    border-radius: 50%;
                    animation: spin 1s linear infinite;
                }
                @keyframes spin { to { transform: rotate(360deg); } }
                p { margin-top: 16px; font-size: 15px; }
            </style>
        </head>
        <body>
            <div class="spinner"></div>
            <p>\(L10n.Articles.loadingWord(word.htmlEscaped))</p>
        </body>
        </html>
        """
    }
    
    // MARK: - Not Found State
    
    /// Render not found state HTML
    static func renderNotFound(
        word: String,
        dictName: String,
        traitCollection: UITraitCollection
    ) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <style>
                body {
                    font-family: -apple-system, system-ui;
                    text-align: center;
                    padding-top: 40%;
                    color: \(cssColor(.secondaryLabel, traitCollection));
                    background: transparent;
                }
                .icon { font-size: 48px; margin-bottom: 16px; }
                h3 { margin: 0; color: \(cssColor(.label, traitCollection)); }
                p { margin: 8px 0 0 0; font-size: 14px; }
            </style>
        </head>
        <body>
            <div class="icon">🔍</div>
            <h3>\(L10n.Articles.notFoundTitle(word.htmlEscaped))</h3>
            <p>\(L10n.Articles.notFoundSubtitle(dictName: dictName.htmlEscaped))</p>
        </body>
        </html>
        """
    }
    
    // MARK: - Empty State
    
    /// Render empty state HTML (no article selected)
    static func renderEmpty(traitCollection: UITraitCollection) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <style>
                body {
                    font-family: -apple-system, system-ui;
                    display: flex;
                    flex-direction: column;
                    align-items: center;
                    justify-content: center;
                    height: 80vh;
                    margin: 0;
                    color: \(cssColor(.tertiaryLabel, traitCollection));
                    background: transparent;
                }
                .icon { font-size: 64px; margin-bottom: 16px; }
                p { font-size: 17px; color: \(cssColor(.secondaryLabel, traitCollection)); }
            </style>
        </head>
        <body>
            <div class="icon">📖</div>
            <p>\(L10n.Articles.selectWord)</p>
        </body>
        </html>
        """
    }
    
    // MARK: - Helpers
    
    /// Convert UIColor to CSS rgba string
    static func cssColor(_ uiColor: UIColor, _ traitCollection: UITraitCollection) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor.resolvedColor(with: traitCollection).getRed(&r, green: &g, blue: &b, alpha: &a)
        return "rgba(\(Int(r*255)), \(Int(g*255)), \(Int(b*255)), \(a))"
    }
}

// MARK: - String HTML Escaping

extension String {
    var htmlEscaped: String {
        self.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
