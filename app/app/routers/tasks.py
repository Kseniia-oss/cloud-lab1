from fastapi import APIRouter, HTTPException, Response, status
from sqlalchemy import select

from app.models import Task
from app.schemas import TaskCreate, TaskOut, TaskUpdate
from app.security import CurrentUser, DbSession

router = APIRouter(prefix="/tasks", tags=["tasks"])


def _get_own_task(task_id: int, user, db) -> Task:
    task = db.get(Task, task_id)
    if task is None or task.owner_id != user.id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Task not found")
    return task


@router.get("", response_model=list[TaskOut])
def list_tasks(user: CurrentUser, db: DbSession, done: bool | None = None):
    query = select(Task).where(Task.owner_id == user.id).order_by(Task.id)
    if done is not None:
        query = query.where(Task.done == done)
    return db.scalars(query).all()


@router.post("", response_model=TaskOut, status_code=status.HTTP_201_CREATED)
def create_task(data: TaskCreate, user: CurrentUser, db: DbSession):
    task = Task(title=data.title, description=data.description, owner_id=user.id)
    db.add(task)
    db.commit()
    db.refresh(task)
    return task


@router.get("/{task_id}", response_model=TaskOut)
def get_task(task_id: int, user: CurrentUser, db: DbSession):
    return _get_own_task(task_id, user, db)


@router.patch("/{task_id}", response_model=TaskOut)
def update_task(task_id: int, data: TaskUpdate, user: CurrentUser, db: DbSession):
    task = _get_own_task(task_id, user, db)
    for field, value in data.model_dump(exclude_unset=True).items():
        setattr(task, field, value)
    db.commit()
    db.refresh(task)
    return task


@router.delete("/{task_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_task(task_id: int, user: CurrentUser, db: DbSession):
    task = _get_own_task(task_id, user, db)
    db.delete(task)
    db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)
