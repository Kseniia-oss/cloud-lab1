import sys

from sqlalchemy import text

from app.database import engine

DEFAULT = [
    "SELECT (SELECT count(*) FROM users) AS users, (SELECT count(*) FROM tasks) AS tasks",
    "SELECT t.id, u.username, t.title, t.done, t.created_at FROM tasks t JOIN users u ON u.id = t.owner_id "
    "ORDER BY t.id DESC LIMIT 10",
]


def run(sql: str) -> None:
    print(f"\n> {sql}")
    with engine.begin() as conn:
        result = conn.execute(text(sql))
        if result.returns_rows:
            print(" | ".join(result.keys()))
            for row in result:
                print(" | ".join(str(v) for v in row))
        else:
            print(f"OK, rows affected: {result.rowcount}")


if __name__ == "__main__":
    for query in sys.argv[1:] or DEFAULT:
        run(query)
