# OCI media storage cutover

The owner has explicitly approved public access to customer product reference images and generated creatives. They are stored under `creatives/` in the existing public `rithena` bucket. Anyone with an object URL can read it; the prefix is for organization, not access control. Do not store credentials, private drafts, or other sensitive data there.

The application keeps the existing `storage_bucket` and `storage_path` database values. OCI keys are prefixed with `creatives/` and the former Supabase bucket name, for example `creatives/creative-media/<storage_path>` or `creatives/product-assets/<storage_path>`. Existing Supabase objects remain readable during cutover.

## Configuration

Set these server-side values in both Vercel Production environment variables and Supabase Edge Function secrets:

- `OCI_ACCESS_KEY` and `OCI_SECRET_KEY`: OCI Customer Secret Key pair. Never use a `NEXT_PUBLIC_` prefix or commit values.
- `OCI_BUCKET=rithena`
- `OCI_NAMESPACE=axr2mzsugevy`
- `OCI_REGION=ca-montreal-1`

For a local migration, put the same OCI values in an ignored `rithena_supabase/.env` or `rithena/.env` file. Production uses `PROD_SERVICE_ROLE_KEY` if provided; otherwise the migration obtains the matching service-role key in memory through the authenticated Supabase CLI using `PROD_ACCESS_TOKEN`. Staging uses its matching `SUPABASE_SERVICE_ROLE_KEY`. The script checks that the target media schema is readable before any storage action. The backend's `npm run storage:secrets:prod` publishes the OCI values to Supabase secrets after `PROD_PROJECT_REF` and `PROD_ACCESS_TOKEN` are configured. Configure the OCI values in Vercel's Production environment and redeploy the Next.js app; Edge Function secrets do not reach Vercel.

## Cutover order

1. Confirm the Customer Secret Key identity can read/write/list/delete objects in `rithena`. Confirm a test object in `creatives/` is anonymously readable, as intended.
2. Confirm the intended Supabase project and matching service key. Run `npm run storage:dry:prod` (or `storage:dry:staging`) and inspect the exact counts. `npm run storage:migrate:prod` copies **only product reference images**, SHA-256-verifies each destination, and checks anonymous read access. Old creatives are not copied.
3. Run `npm run storage:secrets:prod`, deploy the changed Edge Functions (`generation-worker`, `product-generation-worker`, `video-composer`, `publish-worker`), and redeploy Vercel with the same server-side values.
4. Verify onboarding image upload/preview, image and video generation, video composition, media display, and publishing using a test brand. Confirm a new object's public URL works without authentication. Monitor failed storage requests and bandwidth.
5. After verifying the cutover, run `npm run storage:destroy-creatives:prod` to permanently delete only the old Supabase `creative-media` files and their matching media-asset records, as requested. The command refuses deletion if those records are selected by an active schedule or publish job. Previously generated content will need regeneration. Separately, `npm run storage:cleanup:prod` re-verifies copied product references before removing their Supabase originals. Both steps are destructive; run only against the confirmed target project.

The existing public `rithena/music/` objects and `MUSIC_LIBRARY_BASE_URL` are unaffected.
