const fs = require("node:fs");
const fsp = require("node:fs/promises");
const path = require("node:path");
const os = require("node:os");
const crypto = require("node:crypto");
const { spawn, spawnSync } = require("node:child_process");

const MAGIC = Buffer.from("CTENFDAM", "ascii");
const CORE_KEY = Buffer.from("687A4852416D736F356B496E62617857", "hex");
const META_KEY = Buffer.from("2331346C6A6B5F215C5D2630553C2728", "hex");
const CHUNK_SIZE = 1024 * 1024;

class ConversionAbortError extends Error {
  constructor() {
    super("转换已取消");
    this.name = "ConversionAbortError";
  }
}

class BinaryCursor {
  constructor(handle) {
    this.handle = handle;
    this.position = 0;
  }

  async read(length) {
    const buffer = Buffer.alloc(length);
    const { bytesRead } = await this.handle.read(buffer, 0, length, this.position);
    if (bytesRead !== length) {
      throw new Error("文件不完整或 NCM 头部损坏");
    }
    this.position += length;
    return buffer;
  }

  async skip(length) {
    this.position += length;
  }

  async seek(position) {
    this.position = position;
  }

  async readUInt32LE() {
    return (await this.read(4)).readUInt32LE(0);
  }
}

function aes128EcbDecrypt(data, key) {
  const decipher = crypto.createDecipheriv("aes-128-ecb", key, null);
  decipher.setAutoPadding(true);
  return Buffer.concat([decipher.update(data), decipher.final()]);
}

function xorBuffer(data, value) {
  const output = Buffer.from(data);
  for (let index = 0; index < output.length; index += 1) {
    output[index] ^= value;
  }
  return output;
}

function buildKeyBox(keyData) {
  if (!keyData.length) {
    throw new Error("NCM 音频密钥为空");
  }

  const box = Array.from({ length: 256 }, (_, index) => index);
  let c = 0;
  let lastByte = 0;
  let keyOffset = 0;

  for (let index = 0; index < 256; index += 1) {
    const swap = box[index];
    c = (swap + lastByte + keyData[keyOffset]) & 0xff;
    keyOffset += 1;
    if (keyOffset >= keyData.length) {
      keyOffset = 0;
    }
    box[index] = box[c];
    box[c] = swap;
    lastByte = c;
  }

  return box;
}

function decryptAudioChunk(chunk, keyBox, absoluteOffset) {
  const output = Buffer.from(chunk);
  for (let index = 0; index < output.length; index += 1) {
    const position = absoluteOffset + index;
    const j = (position + 1) & 0xff;
    const first = keyBox[j];
    const secondIndex = (first + j) & 0xff;
    const maskIndex = (first + keyBox[secondIndex]) & 0xff;
    output[index] ^= keyBox[maskIndex];
  }
  return output;
}

function parseMetadata(raw) {
  if (raw.length <= 22) {
    throw new Error("歌曲信息字段过短");
  }

  const base64Payload = raw.subarray(22);
  const decoded = Buffer.from(base64Payload.toString("utf8"), "base64");
  const plain = aes128EcbDecrypt(decoded, META_KEY).toString("utf8");
  const jsonText = plain.startsWith("music:") ? plain.slice(6) : plain;
  return JSON.parse(jsonText);
}

async function skipCoverArea(cursor, fileSize) {
  const start = cursor.position;

  try {
    await cursor.skip(5);
    const coverFrameLength = await cursor.readUInt32LE();
    const imageLength = await cursor.readUInt32LE();
    const payloadStart = cursor.position;
    if (imageLength > coverFrameLength || payloadStart + coverFrameLength > fileSize) {
      throw new Error("封面长度字段异常，无法定位音频数据");
    }
    await cursor.seek(payloadStart + coverFrameLength);
    return;
  } catch (_) {
    await cursor.seek(start);
    await cursor.read(4);
    await cursor.read(5);
    const imageLength = await cursor.readUInt32LE();
    const payloadStart = cursor.position;
    if (payloadStart + imageLength > fileSize) {
      throw new Error("封面长度字段异常，无法定位音频数据");
    }
    await cursor.seek(payloadStart + imageLength);
  }
}

async function readHeader(cursor, fileSize) {
  const magic = await cursor.read(8);
  if (!magic.equals(MAGIC)) {
    throw new Error("不是有效的 NCM 文件");
  }

  await cursor.read(2);
  const keyLength = await cursor.readUInt32LE();
  const encryptedKey = xorBuffer(await cursor.read(keyLength), 0x64);
  const decryptedKey = aes128EcbDecrypt(encryptedKey, CORE_KEY);
  if (decryptedKey.length <= 17) {
    throw new Error("NCM 音频密钥异常");
  }
  const keyBox = buildKeyBox(decryptedKey.subarray(17));

  const metadataLength = await cursor.readUInt32LE();
  const encryptedMetadata = xorBuffer(await cursor.read(metadataLength), 0x63);
  const metadata = parseMetadata(encryptedMetadata);

  await skipCoverArea(cursor, fileSize);
  return { keyBox, metadata, audioOffset: cursor.position };
}

function sniffAudioFormat(firstBytes) {
  if (firstBytes.subarray(0, 3).toString("ascii") === "ID3") {
    return "mp3";
  }
  if (firstBytes.length >= 2 && firstBytes[0] === 0xff && (firstBytes[1] & 0xe0) === 0xe0) {
    return "mp3";
  }
  if (firstBytes.subarray(0, 4).toString("ascii") === "fLaC") {
    return "flac";
  }
  if (firstBytes.subarray(0, 4).toString("ascii") === "OggS") {
    return "ogg";
  }
  if (
    firstBytes.length >= 12 &&
    firstBytes.subarray(0, 4).toString("ascii") === "RIFF" &&
    firstBytes.subarray(8, 12).toString("ascii") === "WAVE"
  ) {
    return "wav";
  }
  return "unknown";
}

function artistNames(metadata) {
  const raw = metadata.artist || metadata.artists;
  const names = [];

  if (Array.isArray(raw)) {
    for (const item of raw) {
      if (Array.isArray(item) && typeof item[0] === "string" && item[0]) {
        names.push(item[0]);
      } else if (item && typeof item === "object" && typeof item.name === "string" && item.name) {
        names.push(item.name);
      } else if (typeof item === "string" && item) {
        names.push(item);
      }
    }
  }

  return names.join("、");
}

function safeFilename(name) {
  const cleaned = String(name || "converted")
    .replace(/[\\/:*?"<>|]/g, "_")
    .replace(/\s+/g, " ")
    .trim();
  return (cleaned || "converted").slice(0, 180);
}

function outputStem(inputPath, metadata, renameByMetadata) {
  if (!renameByMetadata) {
    return safeFilename(path.basename(inputPath, path.extname(inputPath)));
  }

  const title = metadata.musicName || metadata.name || path.basename(inputPath, path.extname(inputPath));
  const artists = artistNames(metadata);
  return safeFilename(artists ? `${artists} - ${title}` : title);
}

async function ensureDirectory(directory) {
  await fsp.mkdir(directory, { recursive: true });
}

async function uniqueOutputPath(directory, stem, extension, overwrite) {
  const ext = extension.startsWith(".") ? extension : `.${extension}`;
  const desired = path.join(directory, `${stem}${ext}`);
  if (overwrite || !fs.existsSync(desired)) {
    return desired;
  }

  for (let index = 1; index < 10000; index += 1) {
    const candidate = path.join(directory, `${stem} (${index})${ext}`);
    if (!fs.existsSync(candidate)) {
      return candidate;
    }
  }

  throw new Error(`输出目录里重名文件太多：${path.basename(desired)}`);
}

async function moveReplacing(source, target, overwrite) {
  if (overwrite && fs.existsSync(target)) {
    await fsp.rm(target, { force: true });
  }
  await ensureDirectory(path.dirname(target));
  try {
    await fsp.rename(source, target);
  } catch (error) {
    if (error.code !== "EXDEV") {
      throw error;
    }
    await fsp.copyFile(source, target);
    await fsp.rm(source, { force: true });
  }
}

async function extractNcm(inputPath, signal, onProgress) {
  const stat = await fsp.stat(inputPath);
  const inputHandle = await fsp.open(inputPath, "r");
  const tempDir = await fsp.mkdtemp(path.join(os.tmpdir(), "ncm-batch-mp3-"));
  const tempAudioPath = path.join(tempDir, `${crypto.randomUUID()}.audio`);
  const outputHandle = await fsp.open(tempAudioPath, "w");
  const cursor = new BinaryCursor(inputHandle);

  try {
    const header = await readHeader(cursor, stat.size);
    const totalAudioBytes = Math.max(1, stat.size - header.audioOffset);
    let audioOffset = 0;
    let firstBytes = Buffer.alloc(0);

    while (cursor.position < stat.size) {
      if (signal?.aborted) {
        throw new ConversionAbortError();
      }

      const remaining = stat.size - cursor.position;
      const chunk = await cursor.read(Math.min(CHUNK_SIZE, remaining));
      const decrypted = decryptAudioChunk(chunk, header.keyBox, audioOffset);
      if (firstBytes.length < 64) {
        firstBytes = Buffer.concat([firstBytes, decrypted]).subarray(0, 64);
      }
      await outputHandle.write(decrypted);
      audioOffset += decrypted.length;
      onProgress?.({ phase: "extract", fraction: Math.min(0.86, (audioOffset / totalAudioBytes) * 0.86) });
    }

    await outputHandle.close();
    await inputHandle.close();

    return {
      tempAudioPath,
      tempDir,
      metadata: header.metadata,
      sourceFormat: sniffAudioFormat(firstBytes)
    };
  } catch (error) {
    await outputHandle.close().catch(() => {});
    await inputHandle.close().catch(() => {});
    await fsp.rm(tempDir, { recursive: true, force: true }).catch(() => {});
    throw error;
  }
}

function runProcess(executable, args, signal) {
  return new Promise((resolve, reject) => {
    const child = spawn(executable, args, { windowsHide: true });
    const stderr = [];

    const abort = () => {
      child.kill("SIGTERM");
      reject(new ConversionAbortError());
    };

    if (signal?.aborted) {
      abort();
      return;
    }

    signal?.addEventListener("abort", abort, { once: true });

    child.stderr.on("data", chunk => stderr.push(chunk));
    child.on("error", reject);
    child.on("close", code => {
      signal?.removeEventListener("abort", abort);
      if (code === 0) {
        resolve();
      } else {
        reject(new Error(Buffer.concat(stderr).toString("utf8").trim() || `进程退出码 ${code}`));
      }
    });
  });
}

async function transcodeToMp3(inputPath, outputPath, ffmpegPath, signal) {
  await runProcess(ffmpegPath, [
    "-hide_banner",
    "-loglevel",
    "error",
    "-y",
    "-i",
    inputPath,
    "-codec:a",
    "libmp3lame",
    "-q:a",
    "2",
    outputPath
  ], signal);
}

async function convertNcmFile(inputPath, options, ffmpegPath, signal, onProgress) {
  if (signal?.aborted) {
    throw new ConversionAbortError();
  }

  const outputDirectory = options.outputDirectory;
  await ensureDirectory(outputDirectory);
  const extraction = await extractNcm(inputPath, signal, onProgress);

  try {
    if (extraction.sourceFormat === "unknown") {
      throw new Error("解密后的音频头无法识别，已停止，避免生成打不开的伪 MP3");
    }

    const stem = outputStem(inputPath, extraction.metadata, options.renameByMetadata);
    const preferMp3 = options.outputMode !== "original";

    if (preferMp3 && extraction.sourceFormat !== "mp3" && ffmpegPath) {
      const target = await uniqueOutputPath(outputDirectory, stem, "mp3", options.overwriteExisting);
      onProgress?.({ phase: "transcode", fraction: 0.92 });
      await transcodeToMp3(extraction.tempAudioPath, target, ffmpegPath, signal);
      onProgress?.({ phase: "done", fraction: 1 });
      return {
        outputPath: target,
        sourceFormat: extraction.sourceFormat,
        transcoded: true,
        message: `已从 ${extraction.sourceFormat.toUpperCase()} 转码为 MP3`
      };
    }

    const extension = preferMp3 && extraction.sourceFormat === "mp3" ? "mp3" : extraction.sourceFormat;
    const target = await uniqueOutputPath(outputDirectory, stem, extension, options.overwriteExisting);
    await moveReplacing(extraction.tempAudioPath, target, options.overwriteExisting);
    onProgress?.({ phase: "done", fraction: 1 });
    return {
      outputPath: target,
      sourceFormat: extraction.sourceFormat,
      transcoded: false,
      message: extraction.sourceFormat === "mp3" ? "已导出 MP3" : `已导出 ${extraction.sourceFormat.toUpperCase()}`
    };
  } finally {
    await fsp.rm(extraction.tempDir, { recursive: true, force: true }).catch(() => {});
  }
}

function isExecutableFile(candidate) {
  try {
    const stat = fs.statSync(candidate);
    return stat.isFile();
  } catch (_) {
    return false;
  }
}

function findFfmpeg(candidates = []) {
  for (const candidate of candidates) {
    if (candidate && isExecutableFile(candidate)) {
      return candidate;
    }
  }

  const command = process.platform === "win32" ? "where" : "which";
  const result = spawnSync(command, ["ffmpeg"], { encoding: "utf8", windowsHide: true });
  if (result.status === 0) {
    const first = result.stdout.split(/\r?\n/).map(line => line.trim()).find(Boolean);
    if (first && isExecutableFile(first)) {
      return first;
    }
  }

  return null;
}

module.exports = {
  ConversionAbortError,
  buildKeyBox,
  convertNcmFile,
  ensureDirectory,
  findFfmpeg,
  safeFilename
};
