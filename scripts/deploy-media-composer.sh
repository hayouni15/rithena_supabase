#!/usr/bin/env bash
set -euo pipefail

: "${GOOGLE_CLOUD_PROJECT:?GOOGLE_CLOUD_PROJECT is required}"
: "${PROD_ACCESS_TOKEN:?PROD_ACCESS_TOKEN is required}"
: "${PROD_PROJECT_REF:?PROD_PROJECT_REF is required}"
: "${CRON_SECRET:?CRON_SECRET is required}"

region="${CLOUD_RUN_REGION:-us-central1}"
composer_secret="${MEDIA_COMPOSER_SECRET:-$CRON_SECRET}"

gcloud run deploy rithena-media-composer \
  --project "$GOOGLE_CLOUD_PROJECT" \
  --region "$region" \
  --source ../rithena/services/media-composer \
  --allow-unauthenticated \
  --set-env-vars "MEDIA_COMPOSER_SECRET=$composer_secret" \
  --quiet

composer_url="$(gcloud run services describe rithena-media-composer --project "$GOOGLE_CLOUD_PROJECT" --region "$region" --format='value(status.url)')"
if [[ -z "$composer_url" ]]; then echo "Cloud Run did not return the composer URL." >&2; exit 1; fi

SUPABASE_ACCESS_TOKEN="$PROD_ACCESS_TOKEN" npx supabase secrets set \
  --project-ref "$PROD_PROJECT_REF" \
  "MEDIA_COMPOSER_URL=$composer_url" \
  "MEDIA_COMPOSER_SECRET=$composer_secret" \
  "MUSIC_LIBRARY_BASE_URL=${MUSIC_LIBRARY_BASE_URL:-https://objectstorage.ca-montreal-1.oraclecloud.com/n/axr2mzsugevy/b/rithena/o/music/}"

echo "Media composer deployed at $composer_url"
echo "Set MEDIA_COMPOSER_URL=$composer_url in rithena_supabase/.env before deploying generation-worker."
