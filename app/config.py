from pathlib import Path

class Settings:

    #Base directory of the whole app package (.../app)
    BASE_DIR: Path = Path(__file__).resolve().parent

    #Where the actual .ps1 / .sh installation scripts live
    SCRIPTS_DIR: Path = BASE_DIR / "scripts"

    APP_NAME: str = "Infrastructure Setup API"
    API_V1_PREFIX: str = "/api/v1"


settings = Settings()
