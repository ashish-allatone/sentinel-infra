from app.config import settings
from app.core.enums import OSType
from app.core.exceptions import ScriptNotFoundError
from app.schemas.setup import SetupResponse

# Mapping from OS -> (relative path under scripts/, script type label,
# command template). {path} is replaced with the resolved absolute path
# to the script file when the command is built.
_SCRIPT_MAP = {
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

#ScriptNotFoundError: if the mapped script file doesn't exist on disk.
def get_script(os_type: OSType) -> SetupResponse:
    
    entry = _SCRIPT_MAP[os_type]
    script_path = settings.SCRIPTS_DIR / entry["relative_path"]

    if not script_path.is_file():
        raise ScriptNotFoundError(os_type=os_type.value, path=str(script_path))

    command = entry["command_template"].format(path=script_path)

    return SetupResponse(
        os=os_type,
        script_type=entry["script_type"],
        script_filename=script_path.name,
        command=command,
    )
