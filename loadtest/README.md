# Запуск k6

З кореня репозиторію в Bash або Git Bash запусти:

```bash
BASE_URL="$(terraform -chdir=infra output -raw app_url)" VUS=40 CACHE_MODE=off k6 run loadtest/tasks.js
```

Перед повтором із `CACHE_MODE=on` увімкни кеш у застосунку. Деталі підготовки та підсумкові метрики описані в [docs/LOADTEST.md](../docs/LOADTEST.md).
