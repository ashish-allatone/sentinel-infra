from pathlib import Path

from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse

from src.config import settings
from src.models import OSType, SetupRequest, SetupResponse

app = FastAPI(title=settings.APP_NAME)

# Maps each supported OS to its install script and the command used to run it.
# {path} is filled in with the resolved absolute path at request time.
SCRIPT_MAP = {
    OSType.WINDOWS: {
        "relative_path": "windows/setup-all.ps1",
        "script_type": "powershell",
        "command_template": 'powershell -ExecutionPolicy Bypass -File "{path}"',
    },
    OSType.LINUX: {
        "relative_path": "linux/setup-all.sh",
        "script_type": "bash",
        "command_template": 'bash "{path}"',
    },
}

BINARY_DIR = settings.SCRIPTS_DIR / "windows" / "Binary"


@app.post(
    f"{settings.API_V1_PREFIX}/setup/script",
    response_model=SetupResponse,
    tags=["setup"],
)
#
def get_setup_script(request: SetupRequest) -> SetupResponse:
    entry = SCRIPT_MAP[request.os]
    script_path = settings.SCRIPTS_DIR / entry["relative_path"]

    if not script_path.is_file():
        # Script missing on disk is a server-side/config problem, not the
        # client's fault -- so this is a 500, not a 400/404.
        raise HTTPException(
            status_code=500,
            detail=f"Installation script for OS '{request.os.value}' not found at path: {script_path}",
        )

    return SetupResponse(
        os=request.os,
        script_type=entry["script_type"],
        script_filename=script_path.name,
        command=entry["command_template"].format(path=script_path),
    )


@app.get(
    f"{settings.API_V1_PREFIX}/binaries/{{name}}",
    response_class=FileResponse,
    tags=["binaries"],
)
def get_binary(name: str) -> FileResponse:
    """Serve a Windows binary (e.g. main.exe) referenced by the setup script."""
    # Allows only the file name, e.g. "main.exe" -- blocks paths such as "../secret-file"
    safe_name = Path(name).name
    if safe_name != name or not safe_name.endswith(".exe"):
        raise HTTPException(status_code=400, detail="Invalid executable name")

    file_path = BINARY_DIR / safe_name
    if not file_path.is_file():
        raise HTTPException(status_code=404, detail=f"Binary '{safe_name}' not found")

    return FileResponse(
        path=file_path,
        media_type="application/octet-stream",
        filename=safe_name,
    )
