import pytest
from unittest.mock import patch, Mock
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from shem.client import Client
from shem.agent import Agent


def mock_response(data, status=200):
    r = Mock()
    r.status_code = status
    r.json.return_value = data
    r.raise_for_status = Mock()
    return r


class TestClientStartAgent:
    def test_returns_agent_with_correct_ids(self):
        with patch("requests.post") as mock_post:
            mock_post.return_value = mock_response(
                {"agent_id": "agent_AABBCCDD", "session_id": "sess_001"}
            )
            client = Client("http://localhost:4000")
            agent = client.start_agent("general", "do something")

        assert isinstance(agent, Agent)
        assert agent.agent_id == "agent_AABBCCDD"
        assert agent.session_id == "sess_001"

    def test_posts_to_correct_url_with_body(self):
        with patch("requests.post") as mock_post:
            mock_post.return_value = mock_response(
                {"agent_id": "agent_AABBCCDD", "session_id": "sess_001"}
            )
            client = Client("http://localhost:4000")
            client.start_agent("coding", "refactor auth")

        mock_post.assert_called_once_with(
            "http://localhost:4000/api/agents",
            json={"preset": "coding", "task": "refactor auth"},
        )

    def test_raises_on_http_error(self):
        with patch("requests.post") as mock_post:
            error_resp = mock_response({"error": "unknown preset"}, 400)
            error_resp.raise_for_status.side_effect = Exception("400 Client Error")
            mock_post.return_value = error_resp
            client = Client("http://localhost:4000")
            with pytest.raises(Exception, match="400"):
                client.start_agent("bad_preset", "task")


class TestClientPresets:
    def test_returns_list_of_preset_names(self):
        with patch("requests.get") as mock_get:
            mock_get.return_value = mock_response(
                [
                    {"name": "general", "description": "..."},
                    {"name": "coding", "description": "..."},
                ]
            )
            client = Client("http://localhost:4000")
            names = client.presets()

        assert names == ["general", "coding"]

    def test_gets_correct_url(self):
        with patch("requests.get") as mock_get:
            mock_get.return_value = mock_response([])
            client = Client("http://localhost:4000")
            client.presets()

        mock_get.assert_called_once_with("http://localhost:4000/api/presets")


class TestClientRoutes:
    def test_returns_routes_dict(self):
        routes = {"default": "llama_cpp:qwen3-27b", "reasoning": "ollama:phi4"}
        with patch("requests.get") as mock_get:
            mock_get.return_value = mock_response(routes)
            client = Client("http://localhost:4000")
            result = client.routes()

        assert result == routes

    def test_gets_correct_url(self):
        with patch("requests.get") as mock_get:
            mock_get.return_value = mock_response({})
            client = Client("http://localhost:4000")
            client.routes()

        mock_get.assert_called_once_with("http://localhost:4000/api/routes")
