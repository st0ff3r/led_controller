all: build up

build:
	docker compose build

up:
	docker compose up -d

down:
	docker compose down

logs:
	docker compose logs -f

sh:
	docker compose exec -it led_controller /bin/bash
