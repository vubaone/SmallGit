import assert from "node:assert/strict";
import { isPublic } from "./config.mjs";

if (isPublic) {
    // Deliberately unauthenticated: visitors must be able to access this too.
    const response = await fetch(
        "https://api.github.com/repos/vubaone/SmallGit/releases/latest",
        {
            headers: {
                Accept: "application/vnd.github+json",
                "User-Agent": "SmallGit-website-check",
            },
            signal: AbortSignal.timeout(20_000),
        },
    );
    assert(
        response.ok,
        `Public release unavailable (HTTP ${response.status}); refusing to publish download links.`,
    );
    const release = await response.json();
    assert(
        !release.draft && !release.prerelease,
        "A public stable release is required",
    );
    assert(
        release.assets?.some(
            (asset) =>
                /^SmallGit-.+-macos-arm64\.zip$/.test(asset.name) &&
                asset.state === "uploaded",
        ),
        "Release must include an uploaded Apple silicon app ZIP",
    );
    console.log(
        `Public download verified without credentials: ${release.tag_name}.`,
    );
} else {
    console.log(
        "Coming-soon mode: no private GitHub download links are published.",
    );
}
