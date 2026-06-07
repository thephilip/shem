import time
import requests
from dataclasses import dataclass


@dataclass
class Result:
    content: str


class Agent:
    def __init__(self, agent_id: str, session_id: str, base_url: str):
        self._id = agent_id
        self._session_id = session_id
        self._base = base_url

    @property
    def agent_id(self) -> str:
        return self._id

    @property
    def session_id(self) -> str:
        return self._session_id

    def status(self) -> str:
        resp = requests.get(f"{self._base}/api/agents/{self._id}")
        resp.raise_for_status()
        return resp.json()["status"]

    def stop(self) -> None:
        requests.delete(f"{self._base}/api/agents/{self._id}")

    def await_result(self, timeout: float = 120.0) -> Result:
        deadline = time.monotonic() + timeout
        while True:
            resp = requests.get(f"{self._base}/api/agents/{self._id}/result")
            resp.raise_for_status()
            data = resp.json()
            if data["status"] == "done":
                return Result(content=data.get("content", ""))
            if data["status"] == "error":
                raise RuntimeError(data.get("error", "agent failed"))
            if time.monotonic() >= deadline:
                raise TimeoutError(f"agent {self._id} did not complete within {timeout}s")
            time.sleep(2)
