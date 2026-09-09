from fastapi import FastAPI

from app.api.v1.router import router as v1_router
from app.config import settings

app = FastAPI(title=settings.APP_NAME)

app.include_router(v1_router, prefix=settings.API_V1_PREFIX)



