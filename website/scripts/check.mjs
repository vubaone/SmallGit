import assert from "node:assert/strict";
import { readFile, stat, readdir } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { isPublic, repo } from "./config.mjs";

const output = resolve(dirname(fileURLToPath(import.meta.url)), "../dist");
const html = await readFile(resolve(output, "index.html"), "utf8");
assert(!html.includes("{{"), "Unresolved template placeholders");
assert.equal((html.match(/<h1\b/g) || []).length, 1, "Exactly one h1");
assert(html.includes("https://smallgit.vuba.one/"), "Canonical domain");
const ids = [...html.matchAll(/\bid="([^"]+)"/g)].map((x) => x[1]);
assert.equal(ids.length, new Set(ids).size, "Unique IDs");
for (const match of html.matchAll(/(?:src|href)="([^"]+)"/g)) {
    const target = match[1];
    if (target.startsWith("#"))
        assert(ids.includes(target.slice(1)), `Missing anchor: ${target}`);
    else if (target.startsWith("/") && target !== "/")
        assert(
            (await stat(resolve(output, target.slice(1)))).isFile(),
            `Missing asset: ${target}`,
        );
    else
        assert(
            target === "/" ||
                target.startsWith("https://") ||
                target.startsWith("mailto:"),
            `Unexpected URL: ${target}`,
        );
}
for (const match of html.matchAll(/<img\b[^>]*>/g))
    assert(/\balt="[^"]+"/.test(match[0]), "Image alt text required");
const structured = JSON.parse(
    html.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/)[1],
);
assert.equal(structured.name, "SmallGit");
assert.equal(structured.url, "https://smallgit.vuba.one/");
assert.equal(structured.isAccessibleForFree, true);
assert(!structured.aggregateRating && !structured.review, "Never invent ratings for search results");
assert(html.includes('rel="alternate" type="text/markdown" href="/index.md"'));
assert(html.includes('rel="describedby" type="text/plain" href="/llms.txt"'));
assert(html.includes('content="index, follow, max-image-preview:large"'));
const markdown = await readFile(resolve(output, "index.md"), "utf8");
const llms = await readFile(resolve(output, "llms.txt"), "utf8");
for (const text of [markdown, llms]) {
    assert(text.startsWith("# SmallGit\n\n> "), "Discovery files have a name and summary");
    assert(!text.includes("{{"), "Discovery files contain no template markers");
    assert(!/<\/?(?:script|img|html)\b/i.test(text), "Clean Markdown, without HTML or image badges");
    for (const match of text.matchAll(/\]\(([^)]+)\)/g))
        assert(/^(https:\/\/|mailto:)/.test(match[1]), "Markdown links work outside the website");
}
assert(llms.includes("https://smallgit.vuba.one/index.md"));
assert(Buffer.byteLength(llms) < 5000, "Keep the AI overview concise");
if (isPublic) {
    assert.equal(structured.downloadUrl, `${repo}/releases/latest`);
    assert.equal(structured.offers.price, 0);
    for (const text of [markdown, llms]) assert(text.includes(`${repo}/releases/latest`));
    assert(markdown.includes("### Current limitations\n"), "Publish limitations alongside features");
    assert(markdown.includes("## Moving from SmartGit\n"));
    assert(!markdown.includes("## Build & run"), "Only explicitly selected public product sections ship");
} else {
    assert(!structured.downloadUrl && !structured.offers && !structured.sameAs);
    for (const text of [markdown, llms])
        assert(!/github\.com|githubusercontent\.com/.test(text), "Preview does not expose private repository links");
}
const robots = await readFile(resolve(output, "robots.txt"), "utf8");
assert(robots.includes("User-agent: *\nAllow: /"));
assert(robots.includes("Sitemap: https://smallgit.vuba.one/sitemap.xml"));
const sitemap = await readFile(resolve(output, "sitemap.xml"), "utf8");
assert.deepEqual([...sitemap.matchAll(/<loc>(.*?)<\/loc>/g)].map((m) => m[1]), ["https://smallgit.vuba.one/"]);
assert(sitemap.includes("<image:loc>https://smallgit.vuba.one/assets/smallgit-main-window.png</image:loc>"));
const top = await readdir(output);
assert.deepEqual(
    top.sort(),
    [
        "404.html",
        "_headers",
        "assets",
        "index.html",
        "index.md",
        "llms.txt",
        "robots.txt",
        "sitemap.xml",
        "styles.css",
    ].sort(),
    "Only intended public files ship",
);
console.log(
    "Website checks passed: metadata, links, anchors, images and output allowlist.",
);
