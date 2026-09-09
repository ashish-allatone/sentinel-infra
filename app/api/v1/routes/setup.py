from fastapi import APIRouter, HTTPException

from app.core.exceptions import ScriptNotFoundError
from app.schemas.setup import SetupRequest, SetupResponse
from app.services import script_provider

router = APIRouter(prefix="/setup", tags=["setup"])


    #Given an OS type, return the matching installation script.

    #Flow: request -> validated by SetupRequest (OSType enum) -> service
    #resolves + reads the file -> SetupResponse returned as JSON.
    
@router.post("/script", response_model=SetupResponse)
def get_setup_script(request: SetupRequest) -> SetupResponse:
    
    try:
        return script_provider.get_script(request.os)
    except ScriptNotFoundError as exc:
        # Script missing on disk is a server-side/config problem, not the
        # client's fault -- so this is a 500, not a 400/404.
        raise HTTPException(status_code=500, detail=str(exc)) from exc
