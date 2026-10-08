# ReachInbox Email Scheduler — Full-Stack Assignment

A production-oriented TypeScript monorepo for scheduled email delivery using Express, PostgreSQL, Prisma, BullMQ, Redis, Ethereal SMTP, Elasticsearch, Google OAuth, Slack OAuth, React and Tailwind CSS.

## Architecture

```text
React + Vite
     |
     v
Express API ---- PostgreSQL / Prisma
     |                 |
     |                 +-- users, senders, email_messages, slack_connections
     |
     +---- BullMQ ---- Redis
     |       |
     |       +---- delayed jobs
     |       +---- persistent workers
     |       +---- Redis-backed hourly rate limiting
     |
     +---- Elasticsearch (email search)
     |
     +---- Ethereal SMTP
     |
     +---- Slack OAuth / notifications
     |
     +---- Bull Board (/admin/queues)
```

## Requirements

- Node.js 20+
- Docker + Docker Compose
- Google OAuth credentials
- Slack OAuth app credentials
- Ethereal account credentials (or let the backend create a test account)
- Optional Elasticsearch credentials for hosted deployments

## Quick start

1. Copy environment files:

```bash
cp backend/.env.example backend/.env
cp frontend/.env.example frontend/.env
```

2. Start infrastructure:

```bash
docker compose up -d postgres redis elasticsearch
```

3. Backend:

```bash
cd backend
npm install
npx prisma generate
npx prisma migrate dev --name init
npm run dev
```

4. In another terminal, start the worker:

```bash
cd backend
npm run worker
```

5. Frontend:

```bash
cd frontend
npm install
npm run dev
```

6. Bull Board:

```text
http://localhost:4000/admin/queues
```

## Environment

See `backend/.env.example` and `frontend/.env.example`.

Important values:

- `WORKER_CONCURRENCY`: number of jobs processed concurrently.
- `MIN_SEND_DELAY_MS`: minimum delay between individual sends.
- `MAX_EMAILS_PER_HOUR_PER_SENDER`: Redis-backed hourly sender limit.
- `REDIS_URL`, `DATABASE_URL`, `ELASTICSEARCH_URL`
- Google OAuth and Slack OAuth values.

## Scheduling model

Each recipient is stored as its own `EmailMessage`. The API creates a BullMQ delayed job using:

```text
delay = max(0, scheduledAt - now)
jobId = emailMessage database id
```

BullMQ stores delayed jobs in Redis, so stopping the API/worker does not erase future jobs.

A separate worker process consumes the queue. On restart, BullMQ resumes persisted jobs.

No cron or `setInterval` scheduler is used.

## Rate limiting

The worker uses Redis atomic Lua logic to reserve a sender's hourly slot. The key is:

```text
email-rate:{senderId}:{UTC-hour-window}
```

When the configured limit is reached, the job is not dropped. It is rescheduled for the next hour window. The reservation also stores the selected ordinal slot so concurrent workers cannot allocate the same position.

The minimum per-email delay is enforced by reserving a Redis send slot with a configurable spacing value. This is global per sender and safe across multiple workers/instances.

## Idempotency

Each email has a unique database ID and BullMQ job ID. The worker atomically claims a scheduled email before sending it. Completed emails cannot be processed again.

SMTP is an external side effect, so absolute exactly-once delivery cannot be mathematically guaranteed across a process crash between SMTP acceptance and the DB commit. To minimize duplicate risk, every message uses a deterministic `Message-ID` and `X-Idempotency-Key`. The database/job layer is idempotent and prevents normal retries from duplicating completed messages.

## Elasticsearch

Email records are indexed when scheduled and updated after send/failure. Search endpoint:

```text
GET /api/emails/search?q=rahul
```

If Elasticsearch is temporarily unavailable, email scheduling is not rejected; indexing is retried by application flow and the relational DB remains the source of truth.

## Google OAuth

Configure an OAuth web client in Google Cloud Console:

- Authorized origin: `http://localhost:5173`
- Authorized redirect URI: `http://localhost:4000/api/auth/google/callback`

## Slack OAuth

Create a Slack app with OAuth scopes:

```text
chat:write
```

Set redirect URI:

```text
http://localhost:4000/api/slack/oauth/callback
```

The dashboard's "Connect Slack" button starts the real OAuth flow. When a sender hits its hourly limit, the worker sends a live Slack message if the user has connected Slack.

## Ethereal

Ethereal is fake SMTP: messages are not delivered to real recipients. The worker logs the Ethereal preview URL.

You can either provide:

```text
ETHEREAL_HOST
ETHEREAL_PORT
ETHEREAL_USER
ETHEREAL_PASSWORD
```

or leave user/password blank and the backend creates a test account at startup.

## API

### Auth

```text
GET /api/auth/google
GET /api/auth/google/callback
GET /api/auth/me
POST /api/auth/logout
```

### Emails

```text
POST /api/emails/schedule
GET  /api/emails/scheduled
GET  /api/emails/sent
GET  /api/emails/search?q=
GET  /api/emails/:id
```

`POST /api/emails/schedule` accepts:

```json
{
  "subject": "Hello",
  "body": "Welcome!",
  "startTime": "2026-10-08T18:00:00.000Z",
  "delayBetweenMs": 2000,
  "hourlyLimit": 100,
  "recipients": ["one@example.com", "two@example.com"]
}
```

For CSV upload, the frontend parses addresses client-side and sends the normalized recipient list.

### Slack

```text
GET  /api/slack/connect
GET  /api/slack/oauth/callback
POST /api/slack/disconnect
GET  /api/slack/status
```

## 1000+ emails at the same time

All recipients become delayed BullMQ jobs. Redis stores them durably. Workers process only the configured concurrency. Sender rate limits reserve future slots, so excess jobs are moved into later hour windows instead of being lost.

## Restart test

1. Schedule an email for 2–5 minutes in the future.
2. Stop both API and worker.
3. Keep Redis/Postgres running.
4. Start API and worker again.
5. BullMQ restores the delayed job and the email is sent.

## Demo checklist

1. Google login.
2. Dashboard user details.
3. Compose a CSV with 5–10 emails.
4. Set start time, delay and hourly limit.
5. Schedule.
6. Show Scheduled tab.
7. Show Bull Board.
8. Stop worker/API.
9. Restart them.
10. Show Sent tab and Ethereal preview.
11. Set hourly limit to 2 and schedule 5 recipients.
12. Show jobs moved to the next hour.
13. Connect Slack and show the real Slack notification.
14. Search an email using Elasticsearch.

## Trade-offs / assumptions

- PostgreSQL is the source of truth; Redis is queue/rate-limit state.
- Elasticsearch is a search index, not the primary database.
- CSV parsing is client-side for a simple browser workflow.
- The sample project uses a single email sender per authenticated user. Multiple sender rows can be added through the DB/API later without changing the worker architecture.
- Ethereal is intentionally used instead of a production SMTP provider.
