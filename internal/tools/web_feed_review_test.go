package tools

import (
	"fmt"
	"strings"
	"testing"
)

func TestWebFetchFeedHTMLContentTypePreservesArticleMetadata(t *testing.T) {
	for _, test := range []struct{ name, body, extractor, published string }{
		{"rss", `<rss version="2.0"><channel><item><title>Article</title><link>https://news.example.test/article</link><pubDate>Mon, 30 Jun 2025 12:00:00 GMT</pubDate><description>Source summary.</description></item></channel></rss>`, "rss_feed", "Mon, 30 Jun 2025 12:00:00 GMT"},
		{"atom", `<feed xmlns="http://www.w3.org/2005/Atom"><entry><title>Article</title><link href="https://news.example.test/article"/><published>2025-06-30T12:00:00Z</published><summary>Source summary.</summary></entry></feed>`, "atom_feed", "2025-06-30T12:00:00Z"},
	} {
		for _, mediaType := range []string{"text/html", "text/html; charset=utf-8"} {
			t.Run(test.name+"/"+mediaType, func(t *testing.T) {
				tool, base := serveWebFeed(t, test.body, mediaType)
				result, _ := executeWebFeed(t, tool, WebFetchArgs{URL: base})
				if result.Extractor != test.extractor {
					t.Fatalf("extractor = %q, want %q", result.Extractor, test.extractor)
				}
				assertWebFeedContains(t, result.Content, "[Article](<https://news.example.test/article>)", "Published: "+test.published, "Feed summary: Source summary.")
				raw, _ := executeWebFeed(t, tool, WebFetchArgs{URL: base, Raw: true})
				if raw.Extractor != extractorRaw || raw.Content != test.body {
					t.Fatal("HTML-labelled feed raw mode changed the response bytes")
				}
			})
		}
	}
	tool, base := serveWebFeed(t, `<html><body><h1>News</h1><rss version="2.0"><channel><title>Nested</title></channel></rss></body></html>`, "text/html")
	result, _ := executeWebFeed(t, tool, WebFetchArgs{URL: base})
	if result.Extractor != "html_text" {
		t.Fatalf("nested feed-like elements changed HTML extraction: %s", result.Extractor)
	}
	assertWebFeedContains(t, result.Content, "News", "Nested")
}

func TestWebFetchFeedAtomPrefersParameterizedArticleMediaTypes(t *testing.T) {
	for _, mediaType := range []string{"text/html; charset=utf-8", "Text/HTML; charset=UTF-8", `application/xhtml+xml; charset="utf-8"`} {
		t.Run(mediaType, func(t *testing.T) {
			body := `<feed xmlns="http://www.w3.org/2005/Atom"><entry><title>Article</title><link rel="alternate" type="application/xml" href="https://news.example.test/article.xml"/><link rel="alternate" type='` + mediaType + `' href="https://news.example.test/article.html"/></entry></feed>`
			tool, base := serveWebFeed(t, body, "application/atom+xml")
			result, _ := executeWebFeed(t, tool, WebFetchArgs{URL: base})
			assertWebFeedContains(t, result.Content, "[Article](<https://news.example.test/article.html>)")
			assertWebFeedExcludes(t, result.Content, "article.xml")
		})
	}
}

func TestWebFetchFeedRejectsLocalhostLinksAndBases(t *testing.T) {
	for _, link := range []string{"http://localhost/article", "https://localhost:8443/article", "http://localhost./article", "http://LOCALHOST/article", "http://console.localhost/article", "http://a.b.LoCaLhOsT.:8080/article"} {
		for _, format := range []string{"rss", "atom"} {
			for _, asBase := range []bool{false, true} {
				t.Run(fmt.Sprintf("%s/%s/base=%t", format, link, asBase), func(t *testing.T) {
					baseAttribute, target := "", link
					if asBase {
						baseAttribute, target = ` xml:base="`+link+`"`, "relative"
					}
					body := `<rss version="2.0"><channel><item` + baseAttribute + `><title>Article</title><link>` + target + `</link></item></channel></rss>`
					if format == "atom" {
						body = `<feed xmlns="http://www.w3.org/2005/Atom"><entry` + baseAttribute + `><title>Article</title><link href="` + target + `"/></entry></feed>`
					}
					tool, base := serveWebFeed(t, body, "application/xml")
					result, _ := executeWebFeed(t, tool, WebFetchArgs{URL: base})
					assertWebFeedContains(t, result.Content, "Source link unavailable.")
					if strings.Contains(strings.ToLower(result.Content), "localhost") || strings.Contains(result.Content, "](<") {
						t.Fatal("a loopback name was emitted as an article link")
					}
				})
			}
		}
	}
}
