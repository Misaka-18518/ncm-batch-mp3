const fs = require("node:fs");
const fsp = require("node:fs/promises");
const path = require("node:path");
const os = require("node:os");
const crypto = require("node:crypto");
const assert = require("node:assert/strict");
const { buildKeyBox, convertNcmFile } = require("../src/shared/ncm-core");

const MAGIC = Buffer.from("CTENFDAM", "ascii");
const CORE_KEY = Buffer.from("687A4852416D736F356B496E62617857", "hex");
const META_KEY = Buffer.from("2331346C6A6B5F215C5D2630553C2728", "hex");

function aesEncrypt(data, key) {
  const cipher = crypto.createCipheriv("aes-128-ecb", key, null);
  cipher.setAutoPadding(true);
  return Buffer.concat([cipher.update(data), cipher.final()]);
}

function xor(data, value) {
  const output = Buffer.from(data);
  for (let index = 0; index < output.length; index += 1) {
    output[index] ^= value;
  }
  return output;
}

function xorWithBox(data, keyBox) {
  const output = Buffer.from(data);
  for (let index = 0; index < output.length; index += 1) {
    const j = (index + 1) & 0xff;
    const first = keyBox[j];
    const secondIndex = (first + j) & 0xff;
    const maskIndex = (first + keyBox[secondIndex]) & 0xff;
    output[index] ^= keyBox[maskIndex];
  }
  return output;
}

async function buildNcm(filePath, audio, audioFormat, title = "Synthetic Track") {
  const keyData = Buffer.from("test-stream-key", "utf8");
  const encryptedKey = xor(aesEncrypt(Buffer.concat([Buffer.from("neteasecloudmusic"), keyData]), CORE_KEY), 0x64);
  const metadata = {
    musicName: title,
    artist: [["Codex", 1]],
    format: audioFormat
  };
  const metaPlain = Buffer.from(`music:${JSON.stringify(metadata)}`, "utf8");
  const metaPayload = Buffer.concat([
    Buffer.from("163 key(Don't modify):"),
    Buffer.from(aesEncrypt(metaPlain, META_KEY).toString("base64"), "utf8")
  ]);
  const encryptedMeta = xor(metaPayload, 0x63);
  const encryptedAudio = xorWithBox(audio, buildKeyBox(keyData));

  const parts = [
    MAGIC,
    Buffer.from([0x02, 0x00]),
    Buffer.alloc(4),
    encryptedKey,
    Buffer.alloc(4),
    encryptedMeta,
    Buffer.alloc(5),
    Buffer.alloc(4),
    Buffer.alloc(4),
    encryptedAudio
  ];
  parts[2].writeUInt32LE(encryptedKey.length, 0);
  parts[4].writeUInt32LE(encryptedMeta.length, 0);
  await fsp.writeFile(filePath, Buffer.concat(parts));
}

async function main() {
  const expectedKeyBoxPrefix = [
    70, 218, 132, 64, 217, 166, 112, 195,
    68, 11, 211, 232, 95, 55, 88, 238,
    228, 34, 90, 131, 76, 19, 50, 174,
    108, 173, 40, 122, 251, 145, 35, 59
  ];
  assert.deepEqual(buildKeyBox(Buffer.from("test-stream-key")).slice(0, expectedKeyBoxPrefix.length), expectedKeyBoxPrefix);

  const tmp = await fsp.mkdtemp(path.join(os.tmpdir(), "ncm-windows-core-test-"));
  try {
    const source = path.join(tmp, "sample.ncm");
    const outputDirectory = path.join(tmp, "out");
    const expectedAudio = Buffer.concat([
      Buffer.from("ID3\x04\x00\x00\x00\x00\x00\x10", "binary"),
      Buffer.from("synthetic audio payload".repeat(64), "utf8")
    ]);
    await buildNcm(source, expectedAudio, "mp3");
    const result = await convertNcmFile(
      source,
      {
        outputDirectory,
        outputMode: "mp3",
        renameByMetadata: true,
        overwriteExisting: false
      },
      null,
      new AbortController().signal
    );

    assert.equal(path.basename(result.outputPath), "Codex - Synthetic Track.mp3");
    assert.equal(fs.readFileSync(result.outputPath).compare(expectedAudio), 0);
    console.log(`windows core roundtrip ok: ${path.basename(result.outputPath)}`);
  } finally {
    await fsp.rm(tmp, { recursive: true, force: true });
  }
}

main().catch(error => {
  console.error(error);
  process.exit(1);
});
