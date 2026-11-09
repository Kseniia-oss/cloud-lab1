from collections.abc import Generator

from sqlalchemy import create_engine, text
from sqlalchemy.orm import DeclarativeBase, Session, sessionmaker

from app.config import get_settings


class Base(DeclarativeBase):
    pass


engine = create_engine(
    get_settings().database_url, pool_pre_ping=True, pool_size=5, pool_recycle=900
)
SessionLocal = sessionmaker(bind=engine, autoflush=False, expire_on_commit=False)


def init_db() -> None:
    from app.models import Task, User

    with engine.begin() as conn:
        conn.execute(text("SELECT pg_advisory_xact_lock(727001)"))
        Base.metadata.create_all(conn, tables=[User.__table__, Task.__table__])


def get_db() -> Generator[Session, None, None]:
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
