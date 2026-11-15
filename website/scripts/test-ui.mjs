import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFile, mkdir } from "node:fs/promises";
import { dirname, resolve, extname } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";
import { execFileSync } from "node:child_process";

const site = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const dist = resolve(site, "dist");
const artifacts = resolve(site, "../SmallGit/.build/website/qa");
await mkdir(resolve(artifacts, "tmp"), { recursive: true });
const headers = Object.fromEntries(
    (await readFile(resolve(site, "_headers"), "utf8"))
        .split("\n\n")[0]
        .split("\n")
        .slice(1)
        .filter(Boolean)
        .map((line) => {
            const colon = line.indexOf(":");
            return [line.slice(0, colon).trim(), line.slice(colon + 1).trim()];
        }),
);
function build(mode) {
    const env = { ...process.env };
    if (mode !== undefined) env.SMALLGIT_PUBLIC_RELEASE = String(mode);
    execFileSync(process.execPath, [resolve(site, "scripts/build.mjs")], {
        env,
        stdio: "pipe",
    });
    execFileSync(process.execPath, [resolve(site, "scripts/check.mjs")], {
        env,
        stdio: "pipe",
    });
}
const types = {
    ".html": "text/html",
    ".css": "text/css",
    ".png": "image/png",
    ".xml": "application/xml",
    ".txt": "text/plain",
    ".md": "text/markdown",
};
const server = createServer(async (req, res) => {
    try {
        const pathname = new URL(req.url, "http://localhost").pathname;
        const path = resolve(
            dist,
            "." + (pathname === "/" ? "/index.html" : pathname),
        );
        if (!path.startsWith(dist + "/")) throw new Error("Invalid path");
        const body = await readFile(path);
        res.writeHead(200, {
            ...headers,
            "Content-Type": types[extname(path)] || "application/octet-stream",
        });
        res.end(body);
    } catch {
        res.writeHead(404, { ...headers, "Content-Type": "text/html" });
        res.end(await readFile(resolve(dist, "404.html")));
    }
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const origin = `http://127.0.0.1:${server.address().port}`;
let browser;
try {
    browser = await chromium.launch({
        headless: true,
        executablePath:
            process.env.SMALLGIT_TEST_BROWSER ||
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        env: { ...process.env, TMPDIR: resolve(artifacts, "tmp") + "/" },
    });
    const failures = [];
    for (const isPublic of [true, false]) {
        build(isPublic);
        const mode = isPublic ? "public" : "coming-soon";
        for (const width of [1440, 768, 390, 320]) {
            const page = await browser.newPage({
                viewport: { width, height: 1000 },
                reducedMotion: "reduce",
            });
            page.on("pageerror", (error) => failures.push(error.message));
            page.on("console", (message) => {
                if (
                    message.type() === "error" &&
                    /Content Security Policy|Refused to/.test(message.text())
                ) {
                    failures.push(message.text());
                }
            });
            const response = await page.goto(origin, {
                waitUntil: "networkidle",
            });
            assert.equal(response.status(), 200);
            assert.equal(
                await page.title(),
                "SmallGit — Free, Open-Source Git Client for macOS",
            );
            assert(await page.locator("h1").isVisible());
            assert(await page.locator(".hero .button").isVisible());
            assert.equal(
                await page.locator(".nav-source").getAttribute("href"),
                isPublic
                    ? "https://github.com/vubaone/SmallGit"
                    : "mailto:dev@vuba.one",
            );
            assert.equal(
                await page
                    .locator(".download-end .button")
                    .getAttribute("href"),
                isPublic
                    ? "https://github.com/vubaone/SmallGit/releases/latest"
                    : "mailto:dev@vuba.one",
            );
            const overflow = await page.evaluate(() =>
                [...document.querySelectorAll("body *")]
                    .filter(
                        (node) =>
                            node.getBoundingClientRect().right >
                                innerWidth + 1 ||
                            node.getBoundingClientRect().left < -1,
                    )
                    .filter((node) => !node.classList.contains("skip-link"))
                    .map((node) => `${node.tagName}.${node.className}`),
            );
            const scroll = await page.evaluate(() => ({
                width: innerWidth,
                actual: document.documentElement.scrollWidth,
                nodes: [...document.querySelectorAll("body *")]
                    .filter((el) => el.scrollWidth > el.clientWidth + 1)
                    .map((el) => ({
                        node: `${el.tagName}.${el.className}`,
                        width: el.clientWidth,
                        scroll: el.scrollWidth,
                    })),
            }));
            assert(
                scroll.actual <= width,
                `Horizontal overflow at ${width}px: ${JSON.stringify(scroll)} ${overflow.join(", ")}`,
            );
            assert(
                await page
                    .locator("img")
                    .evaluateAll((images) =>
                        images.every(
                            (img) => img.complete && img.naturalWidth > 0,
                        ),
                    ),
                "Images load",
            );
            for (const details of await page.locator("details").all()) {
                await details.locator("summary").click();
                assert.equal(await details.getAttribute("open"), "");
                await details.locator("summary").click();
                assert.equal(await details.getAttribute("open"), null);
            }
            await page.goto(origin);
            await page.keyboard.press("Tab");
            assert(
                await page
                    .locator(".skip-link")
                    .evaluate((node) => node === document.activeElement),
                "Keyboard skip link",
            );
            await page.locator("h1").click();
            const download = await page
                .locator(".hero .button")
                .getAttribute("href");
            if (download.startsWith("https://github.com/")) {
                assert.equal(
                    download,
                    "https://github.com/vubaone/SmallGit/releases/latest",
                );
                await page.route(download, (route) =>
                    route.fulfill({
                        status: 200,
                        body: "Release destination verified",
                    }),
                );
                await page.locator(".hero .button").click();
                await page.waitForURL(download);
            } else {
                assert.equal(download, "#download");
                await page.locator(".hero .button").click();
                assert(page.url().endsWith("#download"));
            }
            await page.goto(origin, { waitUntil: "networkidle" });
            await page.screenshot({
                path: resolve(artifacts, `${mode}-landing-${width}.png`),
                fullPage: true,
            });
            if (width === 1440 || width === 390)
                await page.screenshot({
                    path: resolve(artifacts, `${mode}-hero-${width}.png`),
                });
            const missing = await page.goto(origin + "/missing-page");
            assert.equal(missing.status(), 404);
            assert(
                await page
                    .getByRole("link", { name: "Back to SmallGit" })
                    .isVisible(),
            );
            await page.close();
            console.log(
                `PASS ${mode} ${width}px: layout, images, FAQ, keyboard navigation, CTA and 404.`,
            );
        }
    }
    assert.deepEqual(failures, [], "No browser errors");
    console.log(`Headless screenshots: ${artifacts}`);
} finally {
    await browser?.close();
    await new Promise((resolve) => server.close(resolve));
    build(); // Restore the configured production build, even after a failed test.
}
