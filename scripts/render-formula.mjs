#!/usr/bin/env node
// Renders scripts/formula/cb.rb.ejs into a Homebrew formula and writes it to
// stdout. Called from scripts/release.sh once release assets and their
// SHA256SUMS exist; the rendered file is attached to the GitHub release, and
// ryaninvents/homebrew-tap's update-formula workflow picks it up from there
// rather than compare-branch pushing it directly.
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import ejs from "ejs";

const templatePath = path.join(
  path.dirname(fileURLToPath(import.meta.url)),
  "formula",
  "cb.rb.ejs",
);

function requireEnv(name) {
  const value = process.env[name];
  if (!value) {
    throw new Error(`render-formula: missing required env var ${name}`);
  }
  return value;
}

const repo = requireEnv("CB_FORMULA_REPO");
const tag = requireEnv("CB_FORMULA_TAG");

const vars = {
  repo,
  tag,
  version: requireEnv("CB_FORMULA_VERSION"),
  urlBase: `https://github.com/${repo}/releases/download/${tag}`,
  shaMacosArm64: requireEnv("CB_FORMULA_SHA_MACOS_ARM64"),
  shaMacosX86_64: requireEnv("CB_FORMULA_SHA_MACOS_X86_64"),
  shaLinuxArm64: requireEnv("CB_FORMULA_SHA_LINUX_ARM64"),
  shaLinuxX86_64: requireEnv("CB_FORMULA_SHA_LINUX_X86_64"),
};

const template = readFileSync(templatePath, "utf8");
process.stdout.write(ejs.render(template, vars, { filename: templatePath }));
