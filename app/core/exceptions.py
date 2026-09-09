class ScriptNotFoundError(Exception):
    def __init__(self, os_type: str, path: str):
        self.os_type = os_type
        self.path = path
        super().__init__(
            f"Installation script for OS '{os_type}' not found at path: {path}"
        )