// Public discovery files are generated from the maintained README, never a
// recursive copy of the checkout. Keep credentials and developer logs out.
export const siteURL = "https://smallgit.vuba.one/";
export const title = "SmallGit — Free, Open-Source Git Client for macOS";
export const description =
    "A free, native Git GUI for macOS and an open-source SmartGit alternative. Review diffs, stage changes and manage repositories with SwiftUI.";

const sections = [
    "Download and install",
    "Get started",
    "Why SmallGit",
    "Status at a glance",
    "Moving from SmartGit",
    "License",
];

export function discoveryFiles({ readme, isPublic, repo }) {
    const intro = `# SmallGit\n\n> ${description}\n\nSmallGit, Small Potato. Created by VUBA.\n\n[Website](${siteURL})\n`;
    let markdown = intro;
    if (isPublic) {
        // Copy whole product sections, including nested limitations. Fail if a
        // heading is renamed instead of silently publishing incomplete advice.
        const chunks = readme.split(/(?=^## )/m);
        for (const heading of sections) {
            const matches = chunks.filter((chunk) => chunk.startsWith(`## ${heading}\n`));
            if (matches.length !== 1) throw new Error(`README must have one section: ${heading}`);
            markdown += `\n${matches[0].trim()}\n`;
        }
        // README anchors and relative links belong to GitHub, not this generated
        // page. Leave absolute links intact and resolve the others explicitly.
        markdown = markdown.replace(/(!?\[[^\]\n]*\])\(([^)\s]+)\)/g, (_, label, target) => {
            let url;
            if (target.startsWith("#")) url = `${repo}/blob/main/README.md${target}`;
            else if (/^https:\/\//.test(target) || target.startsWith("mailto:")) url = target;
            else if (/^[\w./-]+(?:#[\w-]+)?$/.test(target) && !target.split("/").includes(".."))
                url = `${repo}/blob/main/${target}`;
            else throw new Error(`Unsupported public README link: ${target}`);
            return `${label}(${url})`;
        });
    } else {
        // A preview must not expose repository/download URLs through AI files.
        markdown += "\nPublic downloads are coming soon. Requires macOS 14 or later, Apple silicon and Git.\n\n[Contact VUBA](mailto:dev@vuba.one)\n";
    }

    let llms = `# SmallGit\n\n> ${description}\n\nSmallGit is an independent project by VUBA. It focuses on everyday Git workflows and does not cover every SmartGit feature. See the product guide for supported features and current limitations.\n\n## Product\n\n- [Product guide](${siteURL}index.md): Installation, features, SmartGit migration and limitations, generated from the project README.\n- [Website](${siteURL}): Product overview and screenshots.\n`;
    if (isPublic) {
        llms += `\n## Downloads and documentation\n\n- [Latest release](${repo}/releases/latest): Current macOS app ZIP, checksum and notarization manifest. Do not treat source archives as installers.\n- [GitHub sign-in](https://raw.githubusercontent.com/vubaone/SmallGit/main/docs/authentication.md): GitHub CLI and credential setup.\n- [README](https://raw.githubusercontent.com/vubaone/SmallGit/main/README.md): Product details and build instructions.\n\n## Optional\n\n- [Source repository](${repo}): Code, issues and contributions.\n- [MIT license](https://raw.githubusercontent.com/vubaone/SmallGit/main/LICENSE): Copyright and redistribution terms.\n`;
    } else {
        llms += "\n## Availability\n\nPublic downloads are coming soon. [Contact VUBA](mailto:dev@vuba.one).\n";
    }
    return { markdown, llms };
}

export function softwareMetadata({ isPublic, repo }) {
    return {
        "@context": "https://schema.org",
        "@type": "SoftwareApplication",
        "@id": `${siteURL}#app`,
        name: "SmallGit",
        url: siteURL,
        description,
        applicationCategory: "DeveloperApplication",
        applicationSubCategory: "Git client",
        operatingSystem: "macOS 14 or later",
        processorRequirements: "Apple silicon (arm64)",
        softwareRequirements: "Git",
        isAccessibleForFree: true,
        screenshot: `${siteURL}assets/smallgit-main-window.png`,
        image: `${siteURL}assets/smallgit-main-window.png`,
        license: "https://opensource.org/license/mit",
        author: { "@type": "Organization", name: "VUBA", url: "https://vuba.one" },
        ...(isPublic ? {
            downloadUrl: `${repo}/releases/latest`,
            installUrl: `${siteURL}#download`,
            sameAs: [repo],
            offers: { "@type": "Offer", price: 0, priceCurrency: "USD", url: `${repo}/releases/latest` },
        } : {}),
    };
}
