from pydantic import BaseModel, ConfigDict, Field

from app.core.enums import OSType

class SetupRequest(BaseModel):

    os: OSType = Field(..., description="Target operating system")

    model_config = ConfigDict(
        json_schema_extra={"example": {"os": "windows"}}
    )


class SetupResponse(BaseModel):
    os: OSType
    script_type: str = Field(..., description="e.g. 'powershell' or 'bash'")
    script_filename: str
    command: str = Field(..., description="Command to execute the installation script")

    model_config = ConfigDict(
        json_schema_extra={
            "example": {
                "os": "windows",
                "script_type": "powershell",
                "script_filename": "setup-all.ps1",
                "command": "powershell -ExecutionPolicy Bypass -File \"setup-all.ps1\"",
            }
        }
    )
