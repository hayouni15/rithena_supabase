import { AwsClient } from "npm:aws4fetch@1.0.20";

type Db = { storage: { from(bucket: string): {
  upload(path: string, body: unknown, options?: Record<string, unknown>): Promise<{ data: unknown; error: Error | null }>;
  download(path: string): Promise<{ data: Blob | null; error: Error | null }>;
  createSignedUrl(path: string, expiresIn: number): Promise<{ data: { signedUrl: string } | null; error: Error | null }>;
  createSignedUploadUrl(path: string): Promise<{ data: { signedUrl: string } | null; error: Error | null }>;
  remove(paths: string[]): Promise<{ data: unknown; error: Error | null }>;
} } };

const defaults = { namespace: "axr2mzsugevy", region: "ca-montreal-1" };
const config = () => ({
  namespace: Deno.env.get("OCI_NAMESPACE") || defaults.namespace,
  bucket: Deno.env.get("OCI_BUCKET"),
  region: Deno.env.get("OCI_REGION") || defaults.region,
});
const objectKey = (bucket: string, path: string) => {
  if (!bucket || !path || path.startsWith("/") || path.split("/").includes("..")) throw new Error("Invalid stored object path.");
  return `creatives/${bucket}/${path}`;
};
const encodedKey = (key: string) => key.split("/").map(encodeURIComponent).join("/");

function s3ObjectUrl(bucket: string, path: string) {
  const { namespace, region, bucket: ociBucket } = config();
  if (!ociBucket) throw new Error("An OCI media bucket is not configured.");
  return `https://${namespace}.compat.objectstorage.${region}.oraclecloud.com/${encodeURIComponent(ociBucket)}/${encodedKey(objectKey(bucket, path))}`;
}

function publicObjectUrl(bucket: string, path: string) {
  const { namespace, region, bucket: ociBucket } = config();
  if (!ociBucket) throw new Error("An OCI media bucket is not configured.");
  return `https://objectstorage.${region}.oraclecloud.com/n/${encodeURIComponent(namespace)}/b/${encodeURIComponent(ociBucket)}/o/${encodedKey(objectKey(bucket, path))}`;
}

function client() {
  const accessKeyId = Deno.env.get("OCI_ACCESS_KEY");
  const secretAccessKey = Deno.env.get("OCI_SECRET_KEY");
  if (!accessKeyId || !secretAccessKey) throw new Error("OCI storage credentials are not configured.");
  return new AwsClient({ accessKeyId, secretAccessKey, service: "s3", region: config().region, retries: 2 });
}

async function exists(bucket: string, path: string) {
  if (!config().bucket) return false;
  const response = await client().fetch(s3ObjectUrl(bucket, path), { method: "HEAD" });
  if (response.status === 404) return false;
  if (!response.ok) throw new Error(`OCI object lookup failed (${response.status}).`);
  return true;
}

function failure(error: unknown) {
  return { data: null, error: error instanceof Error ? error : new Error("Storage operation failed.") };
}

export function storageFrom(db: Db, bucket: string) {
  const legacy = db.storage.from(bucket);
  return {
    async upload(path: string, source: Blob | Uint8Array | ReadableStream<Uint8Array>, options: { contentType?: string; upsert?: boolean; duplex?: string } = {}) {
      try {
        const body = source instanceof ReadableStream ? new Uint8Array(await new Response(source).arrayBuffer())
          : source instanceof Blob ? new Uint8Array(await source.arrayBuffer()) : source;
        const response = await client().fetch(s3ObjectUrl(bucket, path), {
          method: "PUT",
          headers: { "content-type": options.contentType || "application/octet-stream", "cache-control": "public, max-age=900", ...(options.upsert ? {} : { "if-none-match": "*" }) },
          body: body as unknown as BodyInit,
        });
        if (response.status === 412) return failure(new Error("Storage object already exists."));
        if (!response.ok) return failure(new Error(`OCI upload failed (${response.status}).`));
        return { data: { path }, error: null };
      } catch (error) { return failure(error); }
    },
    async download(path: string) {
      try {
        if (!config().bucket) return legacy.download(path);
        const response = await client().fetch(s3ObjectUrl(bucket, path), { method: "GET" });
        if (response.ok) return { data: new Blob([await response.arrayBuffer()], { type: response.headers.get("content-type") || "application/octet-stream" }), error: null };
        if (response.status !== 404) return failure(new Error(`OCI download failed (${response.status}).`));
        return legacy.download(path);
      } catch (error) { return failure(error); }
    },
    async createSignedUrl(path: string, expiresIn: number) {
      try {
        if (await exists(bucket, path)) {
          return { data: { signedUrl: publicObjectUrl(bucket, path) }, error: null };
        }
        return legacy.createSignedUrl(path, expiresIn);
      } catch (error) { return failure(error); }
    },
    async createSignedUploadUrl(path: string) {
      try {
        const url = new URL(s3ObjectUrl(bucket, path));
        url.searchParams.set("X-Amz-Expires", "900");
        const request = await client().sign(url.toString(), { method: "PUT", aws: { signQuery: true, service: "s3", region: config().region } });
        return { data: { signedUrl: request.url }, error: null };
      } catch (error) { return failure(error); }
    },
    async remove(paths: string[]) {
      try {
        for (const path of paths) {
          const response = await client().fetch(s3ObjectUrl(bucket, path), { method: "DELETE" });
          if (!response.ok) return failure(new Error(`OCI deletion failed (${response.status}).`));
        }
        return legacy.remove(paths);
      } catch (error) { return failure(error); }
    },
  };
}
