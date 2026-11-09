import logging
import time
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from sqlalchemy import text

from app.config import get_settings
from app.database import engine, init_db
from app.routers import auth, tasks

logging.basicConfig(
    level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s"
)
log = logging.getLogger("app")


@asynccontextmanager
async def lifespan(_: FastAPI):
    init_db()
    log.info("started, version=%s", get_settings().app_version)
    yield


app = FastAPI(
    title="Tasks API",
    description="REST API списку задач. Лабораторна робота 1 з хмарних технологій (AWS ECS Fargate + RDS).",
    version=get_settings().app_version,
    lifespan=lifespan,
)


@app.middleware("http")
async def access_log(request: Request, call_next):
    start = time.perf_counter()
    try:
        response = await call_next(request)
    except Exception:
        log.exception("unhandled error %s %s", request.method, request.url.path)
        response = JSONResponse({"detail": "Internal Server Error"}, status_code=500)
    if request.url.path != "/health":
        log.info(
            "request method=%s path=%s status=%s duration_ms=%.1f",
            request.method,
            request.url.path,
            response.status_code,
            (time.perf_counter() - start) * 1000,
        )
    return response


@app.get("/", tags=["meta"])
def root():
    return {
        "service": "tasks-api",
        "version": get_settings().app_version,
        "message": "Hello from AWS ECS Fargate!",
        "docs": "/docs",
    }


@app.get("/health", tags=["meta"])
def health():
    try:
        with engine.connect() as conn:
            conn.execute(text("SELECT 1"))
    except Exception:
        log.exception("health check: database unavailable")
        return JSONResponse(
            {"status": "error", "database": "unavailable"}, status_code=503
        )
    return {"status": "ok", "database": "ok"}


app.include_router(auth.router)
app.include_router(tasks.router)
