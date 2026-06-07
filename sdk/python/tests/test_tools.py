import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from shem.tools import tool, _registry


def setup_function():
    _registry.clear()


class TestToolDecorator:
    def setup_method(self):
        _registry.clear()

    def test_registers_function_with_name_and_description(self):
        @tool(description="Return greeting")
        def greet(name: str) -> str:
            return f"hello {name}"

        assert len(_registry) == 1
        assert _registry[0]["name"] == "greet"
        assert _registry[0]["description"] == "Return greeting"

    def test_decorated_function_still_callable(self):
        @tool(description="Add two numbers")
        def add(a: int, b: int) -> int:
            return a + b

        assert add(2, 3) == 5

    def test_schema_infers_str_annotation(self):
        @tool(description="Echo")
        def echo(msg: str) -> str:
            return msg

        schema = _registry[0]["input_schema"]
        assert schema["properties"]["msg"]["type"] == "string"
        assert "msg" in schema["required"]

    def test_schema_infers_int_annotation(self):
        @tool(description="Square")
        def square(n: int) -> int:
            return n * n

        schema = _registry[0]["input_schema"]
        assert schema["properties"]["n"]["type"] == "integer"

    def test_schema_infers_float_annotation(self):
        @tool(description="Half")
        def half(x: float) -> float:
            return x / 2

        schema = _registry[0]["input_schema"]
        assert schema["properties"]["x"]["type"] == "number"

    def test_schema_infers_bool_annotation(self):
        @tool(description="Negate")
        def negate(flag: bool) -> bool:
            return not flag

        schema = _registry[0]["input_schema"]
        assert schema["properties"]["flag"]["type"] == "boolean"

    def test_unannotated_param_defaults_to_string(self):
        @tool(description="Generic")
        def generic(x) -> str:
            return str(x)

        schema = _registry[0]["input_schema"]
        assert schema["properties"]["x"]["type"] == "string"

    def test_param_with_default_not_in_required(self):
        @tool(description="Optional")
        def greet_optional(name: str, greeting: str = "hello") -> str:
            return f"{greeting} {name}"

        schema = _registry[0]["input_schema"]
        assert "name" in schema["required"]
        assert "greeting" not in schema["required"]

    def test_multiple_tools_registered(self):
        @tool(description="First")
        def first() -> str:
            return "a"

        @tool(description="Second")
        def second() -> str:
            return "b"

        assert len(_registry) == 2
        names = [e["name"] for e in _registry]
        assert "first" in names
        assert "second" in names
