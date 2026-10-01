import json
import pathlib
import sys

import pytest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))


@pytest.fixture(scope="session")
def vectors():
    return json.loads((pathlib.Path(__file__).parent / "vectors.json").read_text())
