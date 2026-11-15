import { mkdir, readFile, writeFile, copyFile, rm } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { isPublic, repo } from "./config.mjs";
import { title, description, discoveryFiles, softwareMetadata } from "./discovery.mjs";

const site = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const root = resolve(site, "..");
const output = resolve(site, "dist");
const values = {
    SEO_TITLE: title,
    SEO_DESCRIPTION: description,
    STRUCTURED_DATA: JSON.stringify(softwareMetadata({ isPublic, repo }), null, 4).replaceAll("<", "\\u003c"),
    SOURCE_URL: isPublic ? repo : "mailto:dev@vuba.one",
    SOURCE_LABEL: isPublic ? "GitHub" : "Contact",
    DOWNLOAD_URL: isPublic ? `${repo}/releases/latest` : "#download",
    DOWNLOAD_LABEL: isPublic
        ? "Download for Mac"
        : "Public release coming soon",
    DOWNLOAD_END_URL: isPublic
        ? `${repo}/releases/latest`
        : "mailto:dev@vuba.one",
    DOWNLOAD_END_LABEL: isPublic ? "Download for Mac" : "Get in touch",
    RELEASE_NOTE: isPublic
        ? "macOS 14+ · Apple silicon · Free & open source"
        : "macOS 14+ · Apple silicon · Public download coming soon",
    INSTALL_TEXT: isPublic
        ? `Get the ZIP from <a href="${repo}/releases/latest">GitHub Releases</a>.`
        : "Public downloads will be available here once the repository opens.",
    SUPPORT_TEXT: isPublic
        ? `Please <a href="${repo}/issues/new/choose">open a GitHub issue</a>.`
        : 'Email <a href="mailto:dev@vuba.one">dev@vuba.one</a> with feedback.',
};
await rm(output, { recursive: true, force: true });
await mkdir(resolve(output, "assets"), { recursive: true });
let html = await readFile(resolve(site, "index.html"), "utf8");
html = html.replace(/\{\{([A-Z_]+)\}\}/g, (_, key) => {
    if (!(key in values)) throw new Error(`Unknown template variable: ${key}`);
    return values[key];
});
await writeFile(resolve(output, "index.html"), html);
const discovery = discoveryFiles({
    readme: await readFile(resolve(root, "README.md"), "utf8"),
    isPublic,
    repo,
});
await writeFile(resolve(output, "index.md"), discovery.markdown);
await writeFile(resolve(output, "llms.txt"), discovery.llms);
for (const name of [
    "styles.css",
    "404.html",
    "_headers",
    "robots.txt",
    "sitemap.xml",
]) {
    await copyFile(resolve(site, name), resolve(output, name));
}
await copyFile(
    resolve(root, "screens/smallgit-main-window.png"),
    resolve(output, "assets/smallgit-main-window.png"),
);
await copyFile(
    resolve(root, "resources/small-potato.png"),
    resolve(output, "assets/small-potato.png"),
);
console.log(
    `Built website/dist (${isPublic ? "public GitHub downloads" : "coming-soon mode"}).`,
);
