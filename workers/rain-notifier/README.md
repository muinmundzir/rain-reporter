# Rain Notifier Cloudflare Worker

Free-tier Cloudflare Worker that verifies Firebase Auth ID tokens and sends FCM HTTP v1 topic notifications (`rain_<geohash5>`) for `Heavy` and `Storm` rain reports.

## Local Tests

```bash
npm test
```

## Deploy to Cloudflare (Free Tier, No Card)

1. Log in to Cloudflare Wrangler:
   ```bash
   npx wrangler login
   ```
2. Generate a Firebase Service Account JSON in Firebase Console (`Project Settings → Service accounts → Generate new private key`) and store its `client_email` and `private_key` as Wrangler secrets (never commit the JSON):
   ```bash
   npx wrangler secret put FIREBASE_CLIENT_EMAIL
   npx wrangler secret put FIREBASE_PRIVATE_KEY
   ```
3. Deploy the Worker:
   ```bash
   npx wrangler deploy
   ```
4. Copy the deployed `https://rain-notifier.<your-subdomain>.workers.dev` URL into your local gitignored `mapbox.json` as `"NOTIFY_WORKER_URL"`.
