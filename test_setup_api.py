import json
from fastapi.testclient import TestClient
from app.main import app

client = TestClient(app)

print("Testing Windows OS")
response = client.post("/api/v1/setup/script", json={"os": "windows"})
print(f"Status Code: {response.status_code}")
print(json.dumps(response.json(), indent=2))

print("\nTesting Linux OS")
response = client.post("/api/v1/setup/script", json={"os": "linux"})
print(f"Status Code: {response.status_code}")
print(json.dumps(response.json(), indent=2))

