import { PutObjectCommand, S3Client } from "@aws-sdk/client-s3";
import { randomUUID } from "node:crypto";
import { config, hasObjectStorage } from "./config.js";

type UploadResult = {
  objectKey: string;
  audioUrl: string | null;
  bytes: number;
};

let s3Client: S3Client | null = null;
if (hasObjectStorage()) {
  s3Client = new S3Client({
    endpoint: config.storage.endpoint,
    region: config.storage.region,
    forcePathStyle: true,
    credentials: {
      accessKeyId: config.storage.accessKeyId as string,
      secretAccessKey: config.storage.secretAccessKey as string
    }
  });
}

function parseBase64Audio(input: string): { contentType: string; buffer: Buffer } {
  if (input.startsWith("data:")) {
    const [prefix, encoded] = input.split(",", 2);
    const match = prefix.match(/^data:(.+);base64$/);
    if (!match || !encoded) {
      throw new Error("Invalid data URL audio payload");
    }
    return {
      contentType: match[1],
      buffer: Buffer.from(encoded, "base64")
    };
  }

  return {
    contentType: "audio/m4a",
    buffer: Buffer.from(input, "base64")
  };
}

export async function maybeUploadAudio(params: {
  userId: string;
  sourceId: string;
  base64: string;
  contentType?: string | null;
}): Promise<UploadResult | null> {
  if (!s3Client || !config.storage.bucket) {
    return null;
  }

  const parsed = parseBase64Audio(params.base64);
  const contentType = params.contentType ?? parsed.contentType;
  const extension = contentType.includes("wav")
    ? "wav"
    : contentType.includes("mpeg")
      ? "mp3"
      : "m4a";
  const objectKey = `recordings/${params.userId}/${new Date().toISOString().slice(0, 10)}/${params.sourceId}-${randomUUID()}.${extension}`;

  await s3Client.send(
    new PutObjectCommand({
      Bucket: config.storage.bucket,
      Key: objectKey,
      Body: parsed.buffer,
      ContentType: contentType
    })
  );

  const base = config.storage.publicBaseUrl?.replace(/\/$/, "");
  return {
    objectKey,
    audioUrl: base ? `${base}/${objectKey}` : null,
    bytes: parsed.buffer.byteLength
  };
}
