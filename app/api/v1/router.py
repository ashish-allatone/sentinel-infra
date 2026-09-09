from fastapi import APIRouter

from app.api.v1.routes import setup

router = APIRouter()

router.include_router(setup.router)
