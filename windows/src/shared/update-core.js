const RELEASE_OWNER = "enshuwu46-png";
const RELEASE_REPOSITORY = "ncm-batch-mp3";
const LATEST_RELEASE_API = `https://api.github.com/repos/${RELEASE_OWNER}/${RELEASE_REPOSITORY}/releases/latest`;

function versionParts(version) {
  const normalized = String(version || "")
    .trim()
    .replace(/^v/i, "")
    .split(/[+-]/, 1)[0];

  if (!/^\d+(?:\.\d+){0,2}$/.test(normalized)) {
    return null;
  }

  return normalized.split(".").map(Number);
}

function isVersionNewer(latest, current) {
  const latestParts = versionParts(latest);
  const currentParts = versionParts(current);
  if (!latestParts || !currentParts) {
    return false;
  }

  const length = Math.max(latestParts.length, currentParts.length);
  for (let index = 0; index < length; index += 1) {
    const newest = latestParts[index] || 0;
    const installed = currentParts[index] || 0;
    if (newest !== installed) {
      return newest > installed;
    }
  }
  return false;
}

function officialReleaseURL(release) {
  const tagName = String(release?.tag_name || "").trim();
  const releaseURL = String(release?.html_url || "").trim();
  if (!tagName || !releaseURL) {
    return null;
  }

  try {
    const parsed = new URL(releaseURL);
    const expectedPath = `/${RELEASE_OWNER}/${RELEASE_REPOSITORY}/releases/tag/${encodeURIComponent(tagName)}`;
    if (parsed.protocol !== "https:" || parsed.hostname !== "github.com" || parsed.pathname !== expectedPath) {
      return null;
    }
    return parsed.toString();
  } catch {
    return null;
  }
}

module.exports = {
  LATEST_RELEASE_API,
  isVersionNewer,
  officialReleaseURL,
  versionParts
};
