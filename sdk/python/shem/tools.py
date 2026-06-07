import inspect
from typing import Callable

_registry: list[dict] = []

_TYPE_MAP = {
    str: "string",
    int: "integer",
    float: "number",
    bool: "boolean",
}


def _build_schema(fn: Callable) -> dict:
    sig = inspect.signature(fn)
    props = {}
    required = []
    for name, param in sig.parameters.items():
        ann = param.annotation
        json_type = _TYPE_MAP.get(ann, "string")
        props[name] = {"type": json_type}
        if param.default is inspect.Parameter.empty:
            required.append(name)
    schema: dict = {"type": "object", "properties": props}
    if required:
        schema["required"] = required
    return schema


def tool(description: str) -> Callable:
    def decorator(fn: Callable) -> Callable:
        _registry.append(
            {
                "name": fn.__name__,
                "description": description,
                "fn": fn,
                "input_schema": _build_schema(fn),
            }
        )
        return fn

    return decorator
