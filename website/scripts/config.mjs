import { readFile } from "node:fs/promises";

const config = JSON.parse(
    await readFile(new URL("../site.config.json", import.meta.url), "utf8"),
);
if (typeof config.publicRelease !== "boolean")
    throw new Error("publicRelease must be a boolean");
const override = process.env.SMALLGIT_PUBLIC_RELEASE;
if (override !== undefined && !["true", "false"].includes(override)) {
    throw new Error("SMALLGIT_PUBLIC_RELEASE must be true or false");
}
export const isPublic =
    override === undefined ? config.publicRelease : override === "true";
export const repo = "https://github.com/vubaone/SmallGit";
