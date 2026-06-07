import pytest
from unittest.mock import patch, Mock
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from shem.agent import Agent, Result


def mock_response(data, status=200):
    r = Mock()
    r.status_code = status
    r.json.return_value = data
    r.raise_for_status = Mock()
    return r


class TestAgentStatus:
    def test_returns_status_string(self):
        with patch("requests.get") as mock_get:
            mock_get.return_value = mock_response({"status": "running"})
            agent = Agent("agent_AA", "sess_01", "http://localhost:4000")
            assert agent.status() == "running"

    def test_gets_correct_url(self):
        with patch("requests.get") as mock_get:
            mock_get.return_value = mock_response({"status": "done"})
            agent = Agent("agent_AA", "sess_01", "http://localhost:4000")
            agent.status()
        mock_get.assert_called_once_with("http://localhost:4000/api/agents/agent_AA")


class TestAgentStop:
    def test_sends_delete_request(self):
        with patch("requests.delete") as mock_del:
            mock_del.return_value = mock_response({"ok": True})
            agent = Agent("agent_AA", "sess_01", "http://localhost:4000")
            agent.stop()
        mock_del.assert_called_once_with("http://localhost:4000/api/agents/agent_AA")


class TestAgentAwaitResult:
    def test_returns_result_when_done_immediately(self):
        with patch("requests.get") as mock_get:
            mock_get.return_value = mock_response({"status": "done", "content": "hello"})
            agent = Agent("agent_AA", "sess_01", "http://localhost:4000")
            result = agent.await_result(timeout=10)
        assert isinstance(result, Result)
        assert result.content == "hello"

    def test_polls_until_done(self):
        responses = [
            mock_response({"status": "running"}),
            mock_response({"status": "running"}),
            mock_response({"status": "done", "content": "answer"}),
        ]
        with patch("requests.get", side_effect=responses), \
             patch("time.sleep"):
            agent = Agent("agent_AA", "sess_01", "http://localhost:4000")
            result = agent.await_result(timeout=60)
        assert result.content == "answer"

    def test_raises_timeout_error(self):
        with patch("requests.get") as mock_get, \
             patch("time.monotonic", side_effect=[0.0, 0.0, 200.0]):
            mock_get.return_value = mock_response({"status": "running"})
            agent = Agent("agent_AA", "sess_01", "http://localhost:4000")
            with pytest.raises(TimeoutError, match="agent_AA"):
                agent.await_result(timeout=10)

    def test_raises_runtime_error_on_error_status(self):
        with patch("requests.get") as mock_get:
            mock_get.return_value = mock_response({"status": "error", "error": "agent failed"})
            agent = Agent("agent_AA", "sess_01", "http://localhost:4000")
            with pytest.raises(RuntimeError, match="agent failed"):
                agent.await_result(timeout=10)
