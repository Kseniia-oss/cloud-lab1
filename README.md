# Tasks API — лабораторна робота 1 з хмарних технологій

REST API для списку задач (to-do) з реєстрацією та JWT-автентифікацією.
Запакований у Docker, розгорнутий в **AWS** (ECS Fargate + RDS PostgreSQL за Application Load Balancer),
уся інфраструктура описана в **Terraform**, деплой — автоматично з **GitHub Actions** через **OIDC**.

**Публічна адреса:** http://ВСТАВИТИ-ВИХІД-app_url-ПІСЛЯ-terraform-apply
**Swagger UI:** http://ВСТАВИТИ-ВИХІД-app_url/docs

## Стек

| Шар | Технологія |
|---|---|
| Застосунок | Python 3.13, FastAPI, SQLAlchemy 2, PostgreSQL 16, PyJWT + bcrypt |
| Контейнер | Docker (multi-stage, `python:3.13.9-slim-bookworm`, non-root), Docker Compose |
| Хмара | AWS: VPC, ALB, ECS Fargate, ECR, RDS PostgreSQL, Secrets Manager, CloudWatch, SNS, Budgets |
| IaC | Terraform ≥ 1.11, AWS provider ~> 6.62 |
| CI/CD | GitHub Actions + OIDC-роль IAM |

## Архітектура

```mermaid
flowchart LR
    U[Користувач] -->|HTTP :80| ALB
    subgraph VPC 10.0.0.0/16
        subgraph Public subnets
            ALB[Application Load Balancer]
            NAT[NAT Gateway]
        end
        subgraph Private app subnets
            T1[ECS Fargate task 1]
            T2[ECS Fargate task 2]
        end
        subgraph Private DB subnets
            RDS[(RDS PostgreSQL)]
        end
    end
    ALB -->|:8000, health check /health| T1 & T2
    T1 & T2 -->|:5432| RDS
    T1 & T2 -->|HTTPS через NAT| AWS[ECR, Secrets Manager, CloudWatch Logs]
    GH[GitHub Actions] -->|OIDC → IAM role| ECR[(ECR)] & ECS[ECS Service]
```

- З інтернету видно **лише ALB**. Контейнери в приватних підмережах без публічних IP.
- Security groups утворюють ланцюжок `ALB → App → DB`: кожен рівень пускає трафік **лише від security group попереднього**, а не від IP-діапазонів.
- База в приватних підмережах без маршруту в інтернет, `publicly_accessible = false`.
- Пароль бази генерує RDS і зберігає в Secrets Manager; ECS підставляє його в змінну середовища `DB_PASSWORD` при старті контейнера. Пароля немає ні в коді, ні в образі, ні в `tfvars`, ні в Terraform state.

## Ендпоінти

| Метод | Шлях | Опис | Авторизація |
|---|---|---|---|
| GET | `/` | Інформація про сервіс і версію (хеш коміту) | — |
| GET | `/health` | Health check (застосунок + база) | — |
| GET | `/docs` | Swagger UI (OpenAPI: `/openapi.json`) | — |
| POST | `/auth/register` | Реєстрація `{username, password}` | — |
| POST | `/auth/login` | Логін (form: `username`, `password`) → JWT | — |
| GET | `/auth/me` | Поточний користувач | JWT |
| GET | `/tasks?done=true` | Список своїх задач | JWT |
| POST | `/tasks` | Створити задачу `{title, description}` | JWT |
| GET | `/tasks/{id}` | Отримати задачу | JWT |
| PATCH | `/tasks/{id}` | Змінити `{title?, description?, done?}` | JWT |
| DELETE | `/tasks/{id}` | Видалити задачу | JWT |

Без токена захищені ендпоінти повертають **401**.

## Структура проєкту

```
.
├── app/                          # Застосунок
│   ├── app/
│   │   ├── main.py               # FastAPI: /, /health, логування запитів
│   │   ├── config.py             # Налаштування зі змінних середовища
│   │   ├── database.py           # Підключення до PostgreSQL, створення таблиць
│   │   ├── models.py             # Таблиці users, tasks
│   │   ├── schemas.py            # Pydantic-схеми запитів/відповідей
│   │   ├── security.py           # bcrypt + видача та перевірка JWT
│   │   ├── dbshell.py            # Показати дані в базі (через ECS Exec)
│   │   └── routers/              # /auth і /tasks
│   ├── tests/test_api.py         # Інтеграційні тести (pytest)
│   ├── Dockerfile
│   ├── requirements.txt
│   └── requirements-dev.txt
├── infra/                        # Terraform
│   ├── versions.tf               # Провайдери, регіон, теги
│   ├── variables.tf / outputs.tf
│   ├── terraform.tfvars.example  # Шаблон (сам terraform.tfvars у .gitignore)
│   ├── budget.tf                 # AWS Budget з email-сповіщеннями
│   ├── network.tf                # VPC, підмережі, IGW, NAT, маршрути
│   ├── security_groups.tf        # ALB → App → DB
│   ├── ecr.tf                    # Приватний реєстр образів
│   ├── rds.tf                    # PostgreSQL + керований пароль
│   ├── secrets.tf                # Ключ підпису JWT у Secrets Manager
│   ├── iam.tf                    # Ролі ECS (execution / task)
│   ├── ecs.tf                    # Кластер, task definition, сервіс, логи
│   ├── alb.tf                    # Load balancer, target group, health check
│   ├── github_oidc.tf            # OIDC-провайдер і роль для GitHub Actions
│   └── monitoring.tf             # Дашборд, алерти, SNS → email
├── .github/workflows/deploy.yml  # CI/CD
├── compose.yaml                  # Локальний запуск: app + PostgreSQL
└── .env.example                  # Шаблон локальних змінних (.env у .gitignore)
```

## Локальний запуск (завдання 1)

Потрібен лише Docker.

```bash
cp .env.example .env        # один раз; впишіть свої паролі
docker compose up --build   # застосунок + PostgreSQL
```

Відкрийте http://localhost:8000/docs. Дані бази лежать у volume `pgdata` і переживають `docker compose down`
(видаляються лише через `docker compose down -v`).

Тести: `cd app && pip install -r requirements-dev.txt && pytest` (потрібна запущена PostgreSQL і змінні `DB_*`, `JWT_SECRET`).

## Розгортання в AWS (завдання 2–7)

Коротко:

```bash
cd infra
cp terraform.tfvars.example terraform.tfvars   # email і owner/repo
terraform init
terraform apply -target=aws_budgets_budget.monthly   # бюджет — першим
terraform apply                                       # уся інфраструктура
```

Далі в GitHub → Settings → Secrets and variables → Actions → **Variables**:
`AWS_ROLE_ARN` = вихід `github_actions_role_arn`, `APP_URL` = вихід `app_url`.
Потім Actions → CI/CD → Run workflow (перший деплой). Кожен наступний push у `main` деплоїться автоматично.

Видалення всього: `terraform destroy`.

## CI/CD (завдання 5)

`.github/workflows/deploy.yml`:

1. **test** — pytest проти справжньої PostgreSQL (service container).
2. **terraform** — `fmt -check` і `validate`.
3. **deploy** (тільки `main`):
   OIDC → тимчасові креденшали ролі `tasks-api-github-actions` →
   `docker build` → push в ECR з тегом **= хеш коміту** →
   нова ревізія task definition з цим образом і `APP_VERSION=<sha>` →
   оновлення ECS-сервісу (rolling update, очікування стабільності) → smoke test.

Довговічних ключів AWS у GitHub немає. Trust policy ролі пускає лише `repo:<owner>/<repo>:ref:refs/heads/main`.

Відкат: деплой попереднього образу (`Re-run` старого workflow, або нова ревізія task definition з попереднім тегом).
Крім того, ECS deployment circuit breaker сам відкочує версію, яка не проходить health check.

## Моніторинг (завдання 7)

- Логи контейнерів → CloudWatch Logs, група `/ecs/tasks-api` (один рядок на запит: метод, шлях, статус, тривалість).
- Дашборд `tasks-api` (посилання — вихід `dashboard_url`): запити, 5xx, латентність p50/p95/p99, CPU/пам'ять ECS, здорові екземпляри, RDS, останні помилки з логів.
- Алерти на email через SNS: ≥ 5 помилок 5xx за 5 хв; немає здорових екземплярів за ALB.
- AWS Budget: лист при 50% фактичних витрат і при прогнозі > 100%.

## Відповідність вимогам

| Завдання | Де реалізовано |
|---|---|
| 1. Контейнер | `app/Dockerfile` (зафіксований тег, залежності окремим шаром, `USER app`), `compose.yaml` (volume `pgdata`) |
| 2. Terraform | `infra/*.tf`: ECR, RDS, ECS Fargate; підключення до бази — env + Secrets Manager |
| 3. Мережева ізоляція | `network.tf`, `security_groups.tf`, `rds.tf` (`publicly_accessible = false`) |
| 4. Load balancer | `alb.tf` (health check `/health`), контейнери без публічних IP |
| 5. CD | `.github/workflows/deploy.yml`, `github_oidc.tf` |
| 6. Безпека доступу | JWT (`app/app/security.py`), 401 без токена, ключ підпису в Secrets Manager |
| 7. Моніторинг | `monitoring.tf`, логи в `ecs.tf` |
| 8. Документація API | Swagger UI на `/docs` |

## Вартість

Приблизно $2–3 на добу, поки інфраструктура працює: NAT Gateway (~$1.1), ALB (~$0.6), 2 задачі Fargate (~$0.6), публічні IPv4,
RDS `db.t4g.micro` (Free Tier / кредити). **Після захисту — `terraform destroy`.**
