import requests
from .agent import Agent


class Client:
    def __init__(self, base_url: str = "http://localhost:4000"):
        self._base = base_url.rstrip("/")

    def start_agent(self, preset: str, task: str) -> Agent:
        resp = requests.post(
            f"{self._base}/api/agents",
            json={"preset": preset, "task": task},
        )
        resp.raise_for_status()
        data = resp.json()
        return Agent(data["agent_id"], data["session_id"], self._base)

    def presets(self) -> list[str]:
        resp = requests.get(f"{self._base}/api/presets")
        resp.raise_for_status()
        return [p["name"] for p in resp.json()]

    def routes(self) -> dict[str, str]:
        resp = requests.get(f"{self._base}/api/routes")
        resp.raise_for_status()
        return resp.json()
