"""Everything the server imports is something it declares.

The APNs client started importing httpx, which was listed only as a test
dependency, and the application stopped starting on a clean install while every
test still passed — because the tests had it. This catches that shape of
mistake, which is the kind nobody notices until a deployment.
"""

from __future__ import annotations

import ast
import pathlib
import sys
import tomllib

ROOT = pathlib.Path(__file__).resolve().parents[1]
APP = ROOT / "app"
PYPROJECT = ROOT / "pyproject.toml"

#: Import name to the distribution that provides it, where they differ.
DISTRIBUTIONS = {
    "jwt": "pyjwt",
    "argon2": "argon2-cffi",
    "dateutil": "python-dateutil",
    "pydantic_settings": "pydantic-settings",
    "pytest_asyncio": "pytest-asyncio",
}


def imported_modules(root: pathlib.Path) -> set[str]:
    modules: set[str] = set()
    for path in root.rglob("*.py"):
        tree = ast.parse(path.read_text(), filename=str(path))
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                modules.update(alias.name.split(".")[0] for alias in node.names)
            elif isinstance(node, ast.ImportFrom) and node.level == 0 and node.module:
                modules.add(node.module.split(".")[0])
    return modules


def declared(section: str) -> set[str]:
    data = tomllib.loads(PYPROJECT.read_text())
    if section == "runtime":
        requirements = data["project"]["dependencies"]
    else:
        requirements = data["project"]["optional-dependencies"][section]

    names = set()
    for requirement in requirements:
        # "httpx[http2]>=0.28" -> "httpx"
        name = requirement.split("[")[0]
        for separator in (">=", "==", "<", ">", "~=", "!="):
            name = name.split(separator)[0]
        names.add(name.strip().lower())
    return names


def third_party(modules: set[str]) -> set[str]:
    return {
        module
        for module in modules
        if module not in sys.stdlib_module_names
        and module != "app"
        and not module.startswith("_")
    }


def test_every_module_the_app_imports_is_a_runtime_dependency():
    needed = {
        DISTRIBUTIONS.get(module, module).lower() for module in third_party(imported_modules(APP))
    }

    assert needed <= declared("runtime"), (
        f"not declared in [project.dependencies]: {sorted(needed - declared('runtime'))}"
    )


def test_every_module_the_tests_import_is_declared_somewhere():
    needed = {
        DISTRIBUTIONS.get(module, module).lower()
        for module in third_party(imported_modules(ROOT / "tests"))
        if module not in {"tests", "generate_client_sql", "pytest"}
    }
    available = declared("runtime") | declared("dev")

    assert needed <= available, f"not declared anywhere: {sorted(needed - available)}"
