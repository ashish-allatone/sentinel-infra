from enum import Enum

#Supported operating systems for infrastructure setup.
class OSType(str, Enum):
    WINDOWS = "windows"
    LINUX = "linux"
