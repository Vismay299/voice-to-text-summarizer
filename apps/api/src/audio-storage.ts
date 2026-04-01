import { mkdir, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { Storage } from "@google-cloud/storage";
import { HOSTED_ENV_KEYS, type HostedChunkStorageMode } from "@voice/shared/hosted";

export interface StoredHostedAudioChunk {
  storageMode: HostedChunkStorageMode;
  storedPath: string;
  storedBytes: number;
}

export interface HostedAudioChunkStorage {
  getStorageMode(): HostedChunkStorageMode;
  storeAudioChunk(objectPath: string, mimeType: string, bytes: Buffer): Promise<StoredHostedAudioChunk>;
}

function resolveFilesystemRoot() {
  return process.env[HOSTED_ENV_KEYS.localAudioDir] ?? "/tmp/voice-to-text-summarizer/audio-chunks";
}

function createGcsStorage(bucketName: string): HostedAudioChunkStorage {
  const storage = new Storage({
    projectId: process.env[HOSTED_ENV_KEYS.gcpProjectId] ?? undefined
  });
  const bucket = storage.bucket(bucketName);

  return {
    getStorageMode() {
      return "gcs";
    },

    async storeAudioChunk(objectPath: string, mimeType: string, bytes: Buffer) {
      const file = bucket.file(objectPath);
      await file.save(bytes, {
        resumable: false,
        contentType: mimeType,
        metadata: {
          cacheControl: "private, max-age=0, no-transform"
        }
      });

      return {
        storageMode: "gcs",
        storedPath: `gs://${bucketName}/${objectPath}`,
        storedBytes: bytes.byteLength
      };
    }
  };
}

function createFilesystemStorage(): HostedAudioChunkStorage {
  const rootDir = resolveFilesystemRoot();

  return {
    getStorageMode() {
      return "filesystem";
    },

    async storeAudioChunk(objectPath: string, mimeType: string, bytes: Buffer) {
      const storedPath = join(rootDir, objectPath);
      await mkdir(dirname(storedPath), { recursive: true });
      await writeFile(storedPath, bytes);
      return {
        storageMode: "filesystem",
        storedPath,
        storedBytes: bytes.byteLength
      };
    }
  };
}

export function createHostedAudioChunkStorage(): HostedAudioChunkStorage {
  const bucketName = process.env[HOSTED_ENV_KEYS.gcsBucketName];
  if (bucketName) {
    return createGcsStorage(bucketName);
  }

  return createFilesystemStorage();
}
