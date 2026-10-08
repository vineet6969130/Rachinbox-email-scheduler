up:
	docker compose up -d postgres redis elasticsearch

down:
	docker compose down

backend:
	cd backend && npm run dev

worker:
	cd backend && npm run worker

frontend:
	cd frontend && npm run dev
